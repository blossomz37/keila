defmodule Keila.Repo.Migrations.HardenDeliveryAttempts do
  use Ecto.Migration

  def up do
    alter table(:messages) do
      add :claim_token, :uuid
      add :claimed_at, :utc_datetime
      add :attempting_at, :utc_datetime
      add :suppressed_at, :utc_datetime
      add :uncertain_at, :utc_datetime
    end

    create index(:messages, [:claim_token])

    create table(:mailings_delivery_attempts) do
      add :message_id, references(:messages, on_delete: :restrict), null: false
      add :attempt_number, :integer, null: false
      add :claim_token, :uuid, null: false
      add :state, :smallint, null: false
      add :provider, :string, null: false
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :provider_receipt, :string
      add :error_class, :string
      add :error_code, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:mailings_delivery_attempts, [:message_id, :attempt_number],
             name: :mailings_delivery_attempts_message_number_index
           )

    create unique_index(:mailings_delivery_attempts, [:message_id],
             where: "state = 0",
             name: :mailings_delivery_attempts_one_in_flight_index
           )

    create table(:contacts_suppressions) do
      add :project_id, references(:projects, on_delete: :restrict), null: false
      add :contact_id, references(:contacts, on_delete: :nilify_all)
      add :email_identity, :string, null: false
      add :reason, :string, null: false
      add :source, :string, null: false
      add :provider_ref, :string
      add :ended_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:contacts_suppressions, [:contact_id])

    create unique_index(:contacts_suppressions, [:project_id, "lower(email_identity)"],
             where: "ended_at IS NULL",
             name: :contacts_suppressions_active_identity_index
           )

    execute("""
    CREATE FUNCTION suppress_pending_messages_for_inactive_contact()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.status <> 0 AND NEW.status IS DISTINCT FROM OLD.status THEN
        UPDATE messages
        SET status = -3,
            suppressed_at = NOW(),
            updated_at = NOW()
        WHERE contact_id = NEW.id
          AND campaign_id IS NOT NULL
          AND status IN (0, 1, 2);
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER suppress_pending_messages_for_inactive_contact
    AFTER UPDATE OF status ON contacts
    FOR EACH ROW EXECUTE FUNCTION suppress_pending_messages_for_inactive_contact();
    """)

    execute("""
    CREATE FUNCTION enforce_delivery_attempt_transition()
    RETURNS trigger AS $$
    BEGIN
      IF OLD.state <> 0 AND NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'terminal delivery attempts are immutable';
      END IF;

      IF OLD.state = 0 AND NEW.state = 0 AND NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'in-flight delivery attempts may only become terminal';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER enforce_delivery_attempt_transition
    BEFORE UPDATE ON mailings_delivery_attempts
    FOR EACH ROW EXECUTE FUNCTION enforce_delivery_attempt_transition();
    """)

    execute("""
    CREATE FUNCTION finalize_hardened_campaign_after_message()
    RETURNS trigger AS $$
    BEGIN
      IF NEW.campaign_id IS NOT NULL AND NEW.status = -4 THEN
        UPDATE mailings_campaigns
        SET state = 3,
            paused_reason = 'uncertain_delivery',
            updated_at = NOW()
        WHERE id = NEW.campaign_id
          AND state IN (1, 2);
      ELSIF NEW.campaign_id IS NOT NULL
            AND NEW.status IN (10, -1, -2, -3)
            AND NOT EXISTS (
              SELECT 1
              FROM messages
              WHERE campaign_id = NEW.campaign_id
                AND status IN (0, 1, 2, 3, -4)
            ) THEN
        UPDATE mailings_campaigns
        SET state = 4,
            completed_at = COALESCE(completed_at, NOW()),
            updated_at = NOW()
        WHERE id = NEW.campaign_id
          AND state IN (1, 2);
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER finalize_hardened_campaign_after_message
    AFTER UPDATE OF status ON messages
    FOR EACH ROW EXECUTE FUNCTION finalize_hardened_campaign_after_message();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS finalize_hardened_campaign_after_message ON messages")
    execute("DROP FUNCTION IF EXISTS finalize_hardened_campaign_after_message()")

    execute("DROP TRIGGER IF EXISTS enforce_delivery_attempt_transition ON mailings_delivery_attempts")
    execute("DROP FUNCTION IF EXISTS enforce_delivery_attempt_transition()")

    execute("DROP TRIGGER IF EXISTS suppress_pending_messages_for_inactive_contact ON contacts")
    execute("DROP FUNCTION IF EXISTS suppress_pending_messages_for_inactive_contact()")

    drop table(:contacts_suppressions)
    drop table(:mailings_delivery_attempts)

    alter table(:messages) do
      remove :uncertain_at
      remove :suppressed_at
      remove :attempting_at
      remove :claimed_at
      remove :claim_token
    end
  end
end
