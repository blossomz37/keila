defmodule Keila.Mailings.H1CampaignPreparationTest do
  use Keila.DataCase, async: true
  use Oban.Testing, repo: Keila.Repo

  alias Keila.{Contacts, Mailings, Projects, Repo}
  alias Keila.Mailings.{AuditEvent, Campaign, CampaignSnapshot, Message}

  setup do
    _root = insert!(:group)
    user = insert!(:user)
    {:ok, project} = Projects.create_project(user.id, params(:project))

    sender =
      insert!(:mailings_sender,
        project_id: project.id,
        config: %Mailings.Sender.Config{type: "test"}
      )

    %{project: project, sender: sender}
  end

  test "draft updates increment revision and reject stale revisions", %{
    project: project,
    sender: sender
  } do
    campaign = campaign_fixture(project, sender)

    assert {:ok, %{revision: 2, subject: "Revision two"}} =
             Mailings.update_campaign(campaign.id, %{subject: "Revision two"}, 1)

    assert {:error, :stale_revision} =
             Mailings.update_campaign(campaign.id, %{subject: "Stale write"}, 1)

    assert %{revision: 2, subject: "Revision two"} = Mailings.get_campaign(campaign.id)
  end

  test "preparation atomically creates one snapshot, audience, state, and audit event", %{
    project: project,
    sender: sender
  } do
    contact = insert!(:contact, project_id: project.id)
    campaign = campaign_fixture(project, sender)
    scheduled_for = future_time()

    assert {:ok, prepared} =
             Mailings.prepare_campaign(
               campaign.id,
               %{},
               campaign.revision,
               scheduled_for,
               mode: :scheduled
             )

    assert prepared.state == :scheduled
    assert prepared.revision == 2
    assert prepared.active_snapshot_id
    assert prepared.scheduled_for == scheduled_for

    snapshot = Repo.get!(CampaignSnapshot, prepared.active_snapshot_id)
    assert snapshot.source_revision == 2
    assert snapshot.audience_count == 1
    assert snapshot.archive_slug
    assert snapshot.content_sha256 =~ ~r/^[a-f0-9]{64}$/

    expected_hash =
      snapshot.render_input
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert snapshot.content_sha256 == expected_hash

    assert %Message{
             campaign_snapshot_id: snapshot_id,
             contact_id: contact_id,
             status: :unrendered,
             recipient_snapshot: %{"email" => email}
           } = Repo.one!(Message)

    assert snapshot_id == snapshot.id
    assert contact_id == contact.id
    assert email == contact.email

    assert %AuditEvent{
             event: "campaign_prepared",
             campaign_id: campaign_id,
             campaign_snapshot_id: audit_snapshot_id
           } = Repo.one!(AuditEvent)

    assert campaign_id == campaign.id
    assert audit_snapshot_id == snapshot.id
  end

  test "zero eligible recipients rolls the entire preparation back", %{
    project: project,
    sender: sender
  } do
    campaign = campaign_fixture(project, sender)

    assert {:error, :no_recipients} =
             Mailings.prepare_campaign(
               campaign.id,
               %{},
               campaign.revision,
               future_time(),
               mode: :scheduled
             )

    assert %{revision: 1, state: :draft, active_snapshot_id: nil} =
             Mailings.get_campaign(campaign.id)

    refute Repo.exists?(CampaignSnapshot)
    refute Repo.exists?(Message)
    refute Repo.exists?(AuditEvent)
  end

  test "repeating the same preparation request is idempotent", %{
    project: project,
    sender: sender
  } do
    insert!(:contact, project_id: project.id)
    campaign = campaign_fixture(project, sender)
    scheduled_for = future_time()

    assert {:ok, first} =
             Mailings.prepare_campaign(
               campaign.id,
               %{},
               campaign.revision,
               scheduled_for,
               mode: :scheduled
             )

    assert {:ok, second} =
             Mailings.prepare_campaign(
               campaign.id,
               %{},
               campaign.revision,
               scheduled_for,
               mode: :scheduled
             )

    assert second.active_snapshot_id == first.active_snapshot_id
    assert Repo.aggregate(CampaignSnapshot, :count) == 1
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(AuditEvent, :count) == 1
  end

  test "rendering uses frozen campaign and contact data after source rows change", %{
    project: project,
    sender: sender
  } do
    contact =
      insert!(:contact,
        project_id: project.id,
        first_name: "Original",
        email: "original@example.org"
      )

    campaign =
      campaign_fixture(project, sender,
        text_body: "Hello {{ contact.first_name }}",
        subject: "Original subject"
      )

    assert {:ok, prepared} =
             Mailings.prepare_campaign(
               campaign.id,
               %{},
               campaign.revision,
               future_time(),
               mode: :scheduled
             )

    assert {:error, :immutable_campaign} =
             Mailings.update_campaign(campaign.id, %{text_body: "Mutated body"})

    from(c in Campaign,
      where: c.id == ^campaign.id,
      update: [set: [text_body: "Mutated body", subject: "Mutated subject"]]
    )
    |> Repo.update_all([])

    {:ok, _contact} =
      Contacts.update_contact(contact.id, %{
        first_name: "Mutated",
        email: "mutated@example.org"
      })

    assert %{success: 1} = Oban.drain_queue(queue: :campaign_renderer)

    message = Repo.one!(Message)
    assert message.status == :ready
    assert message.subject == "Original subject"
    assert message.text_body =~ "Hello Original"
    assert message.recipient_email == "original@example.org"
    assert Mailings.get_campaign(prepared.id).render_ready_at
  end

  test "unscheduling cancels frozen evidence before sending starts", %{
    project: project,
    sender: sender
  } do
    insert!(:contact, project_id: project.id)
    campaign = campaign_fixture(project, sender)

    assert {:ok, prepared} =
             Mailings.prepare_campaign(
               campaign.id,
               %{},
               campaign.revision,
               future_time(),
               mode: :scheduled
             )

    assert {:ok, draft} = Mailings.unschedule_campaign(campaign.id)
    assert draft.state == :draft
    assert draft.revision == 3
    refute draft.active_snapshot_id
    refute draft.scheduled_for

    assert Repo.get!(CampaignSnapshot, prepared.active_snapshot_id).canceled_at
    assert Repo.one!(Message).status == :canceled
    assert Repo.aggregate(AuditEvent, :count) == 2
  end

  defp campaign_fixture(project, sender, attrs \\ []) do
    insert!(
      :mailings_campaign,
      Keyword.merge(
        [
          project_id: project.id,
          sender_id: sender.id,
          settings: %Mailings.Campaign.Settings{type: :text},
          text_body: "Frozen body"
        ],
        attrs
      )
    )
  end

  defp future_time do
    DateTime.utc_now(:second) |> DateTime.add(3600, :second)
  end
end
