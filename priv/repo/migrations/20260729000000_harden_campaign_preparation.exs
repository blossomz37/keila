defmodule Keila.Repo.Migrations.HardenCampaignPreparation do
  use Ecto.Migration

  def up do
    alter table(:mailings_campaigns) do
      add :revision, :integer, null: false, default: 1
      add :state, :smallint, null: false, default: 0
      add :render_ready_at, :utc_datetime
      add :first_attempt_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :paused_reason, :string
    end

    execute("""
    UPDATE mailings_campaigns
    SET state = CASE
      WHEN sent_at IS NOT NULL THEN 4
      WHEN scheduled_for IS NOT NULL THEN 1
      ELSE 0
    END
    """)

    create table(:mailings_campaign_snapshots) do
      add :campaign_id, references(:mailings_campaigns, on_delete: :restrict), null: false
      add :source_revision, :integer, null: false
      add :snapshot_sequence, :integer, null: false
      add :idempotency_key, :string, null: false
      add :render_input, :map, null: false
      add :audience_filter, :map, null: false
      add :renderer_version, :string, null: false
      add :content_sha256, :string, null: false
      add :audience_count, :integer, null: false
      add :archive_slug, :string, null: false
      add :archive_html, :text
      add :archive_text, :text
      add :frozen_at, :utc_datetime, null: false
      add :canceled_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:mailings_campaign_snapshots, [:campaign_id, :snapshot_sequence],
             name: :mailings_campaign_snapshots_campaign_sequence_index
           )

    create unique_index(:mailings_campaign_snapshots, [:archive_slug])

    create unique_index(:mailings_campaign_snapshots, [:campaign_id, :idempotency_key],
             name: :mailings_campaign_snapshots_campaign_idempotency_index
           )

    alter table(:mailings_campaigns) do
      add :active_snapshot_id,
          references(:mailings_campaign_snapshots, on_delete: :restrict)
    end

    create index(:mailings_campaigns, [:active_snapshot_id])

    alter table(:messages) do
      add :campaign_snapshot_id,
          references(:mailings_campaign_snapshots, on_delete: :restrict)

      add :recipient_snapshot, :map
    end

    create index(:messages, [:campaign_snapshot_id])

    create unique_index(:messages, [:campaign_snapshot_id, :contact_id],
             where: "campaign_snapshot_id IS NOT NULL",
             name: :messages_campaign_snapshot_contact_index
           )

    create table(:mailings_audit_events) do
      add :campaign_id, references(:mailings_campaigns, on_delete: :restrict), null: false

      add :campaign_snapshot_id,
          references(:mailings_campaign_snapshots, on_delete: :restrict)

      add :event, :string, null: false
      add :actor, :string, null: false, default: "system"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:mailings_audit_events, [:campaign_id, :inserted_at])

    execute("""
    CREATE FUNCTION reject_campaign_snapshot_mutation()
    RETURNS trigger AS $$
    BEGIN
      IF (to_jsonb(NEW) - ARRAY['canceled_at', 'updated_at'])
          IS DISTINCT FROM
         (to_jsonb(OLD) - ARRAY['canceled_at', 'updated_at']) THEN
        RAISE EXCEPTION 'campaign snapshots are immutable';
      END IF;

      IF OLD.canceled_at IS NOT NULL AND NEW.canceled_at IS DISTINCT FROM OLD.canceled_at THEN
        RAISE EXCEPTION 'campaign snapshot cancellation is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER reject_campaign_snapshot_mutation
    BEFORE UPDATE ON mailings_campaign_snapshots
    FOR EACH ROW EXECUTE FUNCTION reject_campaign_snapshot_mutation();
    """)

    execute("""
    CREATE FUNCTION reject_rendered_message_mutation()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.campaign_snapshot_id IS NOT NULL AND OLD.status <> 0 AND
         ROW(
           NEW.campaign_snapshot_id,
           NEW.recipient_snapshot,
           NEW.recipient_email,
           NEW.recipient_name,
           NEW.subject,
           NEW.html_body,
           NEW.text_body
         ) IS DISTINCT FROM
         ROW(
           OLD.campaign_snapshot_id,
           OLD.recipient_snapshot,
           OLD.recipient_email,
           OLD.recipient_name,
           OLD.subject,
           OLD.html_body,
           OLD.text_body
         ) THEN
        RAISE EXCEPTION 'rendered campaign messages are immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER reject_rendered_message_mutation
    BEFORE UPDATE ON messages
    FOR EACH ROW EXECUTE FUNCTION reject_rendered_message_mutation();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS reject_rendered_message_mutation ON messages")
    execute("DROP FUNCTION IF EXISTS reject_rendered_message_mutation()")

    execute(
      "DROP TRIGGER IF EXISTS reject_campaign_snapshot_mutation ON mailings_campaign_snapshots"
    )

    execute("DROP FUNCTION IF EXISTS reject_campaign_snapshot_mutation()")

    drop table(:mailings_audit_events)

    drop_if_exists index(:messages, [:campaign_snapshot_id, :contact_id],
                     name: :messages_campaign_snapshot_contact_index
                   )

    alter table(:messages) do
      remove :recipient_snapshot
      remove :campaign_snapshot_id
    end

    alter table(:mailings_campaigns) do
      remove :active_snapshot_id
    end

    drop table(:mailings_campaign_snapshots)

    alter table(:mailings_campaigns) do
      remove :paused_reason
      remove :completed_at
      remove :first_attempt_at
      remove :render_ready_at
      remove :state
      remove :revision
    end
  end
end
