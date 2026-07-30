defmodule Keila.Hardening.AcceptThenCrashAdapter do
  @behaviour Swoosh.Adapter

  @impl true
  def validate_config(_config), do: :ok

  @impl true
  def deliver(email, _config) do
    %{owner: owner, table: table} =
      Application.fetch_env!(:keila, __MODULE__) |> Map.new()

    call_number = :ets.update_counter(table, :provider_calls, {2, 1}, {:provider_calls, 0})
    send(owner, {:h0_provider_accepted, call_number, email})

    if call_number == 1 do
      Process.exit(self(), :kill)
    end

    {:ok, %{id: "accepted-#{call_number}"}}
  end
end
defmodule Keila.Hardening.H0SafetyRegressionsTest do
  use KeilaWeb.ConnCase, async: false
  use Oban.Testing, repo: Keila.Repo

  alias Keila.Hardening.AcceptThenCrashAdapter
  alias Keila.{Contacts, Mailings, Projects, Repo}
  alias Keila.Mailings.{DeliveryWorker, Message}

  @moduletag :h0_safety_red

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

  test "a queued campaign message is suppressed when its contact unsubscribes before delivery",
       %{project: project, sender: sender} do
    contact = insert!(:contact, project_id: project.id, status: :active)
    campaign = insert!(:mailings_campaign, project_id: project.id, sender_id: sender.id)

    assert :ok = Mailings.deliver_campaign(campaign.id)
    assert %{success: 1} = Oban.drain_queue(queue: :campaign_renderer)
    assert :ok = Keila.MailingsSchedulerTestHelper.schedule_messages()

    message = message_for(campaign.id, contact.id)
    assert message.status == :queued

    assert %Contacts.Contact{status: :unsubscribed} =
             Contacts.update_contact_status(contact.id, :unsubscribed)

    Oban.drain_queue(queue: :mailer)

    refute_email_sent()
    assert Repo.reload(message).status == :suppressed
  end

  test "a sent campaign and its public archive remain frozen", %{
    conn: conn,
    project: project,
    sender: sender
  } do
    original_body = "Frozen campaign body"

    campaign =
      insert!(:mailings_campaign,
        project_id: project.id,
        sender_id: sender.id,
        public_link_enabled: true,
        settings: %{type: :text},
        text_body: original_body,
        sent_at: DateTime.utc_now(:second)
      )

    result = Mailings.update_campaign(campaign.id, %{"text_body" => "Mutated campaign body"})
    archived = get(conn, Routes.public_campaign_path(conn, :show, campaign.id))

    assert result == {:error, :immutable_campaign}
    assert Mailings.get_campaign(campaign.id).text_body == original_body
    assert text_response(archived, 200) =~ original_body
  end

  test "an accepted provider call followed by a worker crash is not attempted twice", %{
    project: project,
    sender: sender
  } do
    previous_mailer_config = Application.get_env(:keila, Keila.Mailer)
    table = :ets.new(:h0_provider_calls, [:set, :public])

    Application.put_env(
      :keila,
      Keila.Mailer,
      adapter: AcceptThenCrashAdapter
    )

    Application.put_env(
      :keila,
      AcceptThenCrashAdapter,
      owner: self(),
      table: table
    )

    on_exit(fn ->
      Application.put_env(:keila, Keila.Mailer, previous_mailer_config)
      Application.delete_env(:keila, AcceptThenCrashAdapter)
      :ets.delete(table)
    end)

    message =
      insert!(:message,
        project_id: project.id,
        sender_id: sender.id,
        status: :queued
      )

    job = %Oban.Job{args: %{"message_id" => message.id}}
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :perform -> DeliveryWorker.perform(job)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, worker)
    send(worker, :perform)

    assert_receive {:h0_provider_accepted, 1, _email}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert Repo.reload(message).status == :queued

    assert :ok = DeliveryWorker.perform(job)
    assert_receive {:h0_provider_accepted, 2, _email}

    provider_calls = :ets.lookup_element(table, :provider_calls, 2)
    final_status = Repo.reload(message).status

    assert {provider_calls, final_status} == {1, :uncertain}
  end

  defp message_for(campaign_id, contact_id) do
    import Ecto.Query

    from(m in Message,
      where: m.campaign_id == ^campaign_id and m.contact_id == ^contact_id
    )
    |> Repo.one!()
  end
end
