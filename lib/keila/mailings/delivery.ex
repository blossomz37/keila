defmodule Keila.Mailings.Delivery do
  @moduledoc """
  Owns the final recipient eligibility check and durable provider-attempt state.

  No provider call may occur before `begin_attempt/2` commits. Once an attempt is
  in flight, an ambiguous outcome is terminally `uncertain` and is never
  automatically returned to the delivery queue.
  """

  use Keila.Repo

  alias Keila.Contacts.Contact

  alias Keila.Mailings.{
    AuditEvent,
    Campaign,
    ContactSuppression,
    DeliveryAttempt,
    Message
  }

  @pending_statuses [:unrendered, :ready, :queued]

  @spec begin_attempt(Message.id(), Ecto.UUID.t() | nil) ::
          {:ok, Message.t(), DeliveryAttempt.t()}
          | {:suppressed, Message.t()}
          | {:error, atom()}
  def begin_attempt(message_id, job_claim_token \\ nil) do
    Repo.transaction(fn ->
      message =
        from(m in Message, where: m.id == ^message_id, lock: "FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(message) ->
          Repo.rollback(:not_found)

        message.status != :queued ->
          Repo.rollback(message.status)

        stale_claim?(message.claim_token, job_claim_token) ->
          Repo.rollback(:stale_claim)

        not eligible?(message) ->
          suppressed =
            message
            |> change(
              status: :suppressed,
              suppressed_at: now(),
              updated_at: now()
            )
            |> Repo.update!()

          {:suppressed, suppressed}

        true ->
          claim_token = message.claim_token || job_claim_token || Ecto.UUID.generate()
          attempt_number = next_attempt_number(message.id)
          started_at = now()

          attempt =
            %{
              message_id: message.id,
              attempt_number: attempt_number,
              claim_token: claim_token,
              state: :in_flight,
              provider: provider_name(message),
              started_at: started_at
            }
            |> DeliveryAttempt.creation_changeset()
            |> Repo.insert!()

          attempting =
            message
            |> change(
              status: :attempting,
              claim_token: claim_token,
              claimed_at: message.claimed_at || started_at,
              attempting_at: started_at,
              updated_at: started_at
            )
            |> Repo.update!()
            |> Repo.preload(sender: :shared_sender)

          record_first_attempt(attempting.campaign_id, started_at)

          {:ok, attempting, attempt}
      end
    end)
    |> unwrap_transaction()
  end

  @spec accept_attempt(DeliveryAttempt.id(), term()) :: :ok | {:error, atom()}
  def accept_attempt(attempt_id, raw_receipt) do
    receipt = receipt(raw_receipt)

    transition_attempt(attempt_id, :accepted, fn attempt, message, completed_at ->
      attempt
      |> DeliveryAttempt.terminal_changeset(%{
        state: :accepted,
        completed_at: completed_at,
        provider_receipt: receipt
      })
      |> Repo.update!()

      message
      |> change(
        status: :sent,
        sent_at: completed_at,
        receipt: receipt,
        updated_at: completed_at
      )
      |> Repo.update!()

      :ok
    end)
  end

  @spec reject_attempt(DeliveryAttempt.id(), atom() | String.t()) :: :ok | {:error, atom()}
  def reject_attempt(attempt_id, reason) do
    transition_attempt(attempt_id, :rejected, fn attempt, message, completed_at ->
      attempt
      |> DeliveryAttempt.terminal_changeset(%{
        state: :rejected,
        completed_at: completed_at,
        error_class: "provider_rejected",
        error_code: diagnostic_code(reason)
      })
      |> Repo.update!()

      message
      |> change(status: :failed, failed_at: completed_at, updated_at: completed_at)
      |> Repo.update!()

      :ok
    end)
  end

  @spec mark_attempt_uncertain(DeliveryAttempt.id(), atom() | String.t()) ::
          :ok | {:error, atom()}
  def mark_attempt_uncertain(attempt_id, reason) do
    transition_attempt(attempt_id, :uncertain, fn attempt, message, completed_at ->
      attempt
      |> DeliveryAttempt.terminal_changeset(%{
        state: :uncertain,
        completed_at: completed_at,
        error_class: "ambiguous_provider_outcome",
        error_code: diagnostic_code(reason)
      })
      |> Repo.update!()

      message
      |> change(status: :uncertain, uncertain_at: completed_at, updated_at: completed_at)
      |> Repo.update!()

      record_uncertain_audit(message, attempt)
      :ok
    end)
  end

  @spec mark_stale_attempts_uncertain(non_neg_integer()) :: non_neg_integer()
  def mark_stale_attempts_uncertain(stale_after_seconds \\ 300) do
    cutoff = DateTime.add(now(), -stale_after_seconds, :second)

    attempt_ids =
      from(a in DeliveryAttempt,
        where: a.state == :in_flight and a.started_at <= ^cutoff,
        order_by: [asc: a.started_at],
        limit: 500,
        select: a.id
      )
      |> Repo.all()

    Enum.count(attempt_ids, fn attempt_id ->
      mark_attempt_uncertain(attempt_id, :stale_in_flight) == :ok
    end)
  end

  @doc """
  Adds an active project-level suppression and atomically suppresses all
  matching pending campaign messages.
  """
  @spec suppress_identity(Keila.Projects.Project.id(), String.t(), Keyword.t()) ::
          {:ok, ContactSuppression.t()} | {:error, term()}
  def suppress_identity(project_id, email, opts \\ []) do
    identity = email |> String.trim() |> String.downcase()
    contact_id = opts[:contact_id]

    Repo.transaction(fn ->
      existing =
        from(s in ContactSuppression,
          where:
            s.project_id == ^project_id and is_nil(s.ended_at) and
              fragment("lower(?)", s.email_identity) == ^identity,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      suppression =
        existing ||
          (%{
             project_id: project_id,
             contact_id: contact_id,
             email_identity: identity,
             reason: to_string(opts[:reason] || :operator),
             source: to_string(opts[:source] || :operator),
             provider_ref: opts[:provider_ref]
           }
           |> ContactSuppression.creation_changeset()
           |> Repo.insert!())

      from(m in Message,
        where: m.project_id == ^project_id and m.campaign_id != nil,
        where: m.status in ^@pending_statuses,
        where:
          m.contact_id == ^contact_id or
            fragment("lower(?)", m.recipient_email) == ^identity
      )
      |> Repo.update_all(
        set: [status: :suppressed, suppressed_at: now(), updated_at: now()]
      )

      suppression
    end)
  end

  defp transition_attempt(attempt_id, expected_outcome, transition) do
    Repo.transaction(fn ->
      attempt =
        from(a in DeliveryAttempt, where: a.id == ^attempt_id, lock: "FOR UPDATE")
        |> Repo.one()

      cond do
        is_nil(attempt) ->
          Repo.rollback(:not_found)

        attempt.state != :in_flight ->
          Repo.rollback(:already_terminal)

        true ->
          message =
            from(m in Message, where: m.id == ^attempt.message_id, lock: "FOR UPDATE")
            |> Repo.one!()

          if message.status != :attempting do
            Repo.rollback(:invalid_message_state)
          end

          transition.(attempt, message, now())
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
      {:ok, other} -> {:error, {expected_outcome, other}}
    end
  end

  defp eligible?(%Message{campaign_id: nil}), do: true
  defp eligible?(%Message{contact_id: nil}), do: false

  defp eligible?(message) do
    active_contact? =
      from(c in Contact, where: c.id == ^message.contact_id and c.status == :active)
      |> Repo.exists?()

    suppressed? =
      from(s in ContactSuppression,
        where: s.project_id == ^message.project_id and is_nil(s.ended_at),
        where:
          s.contact_id == ^message.contact_id or
            fragment("lower(?)", s.email_identity) ==
              ^String.downcase(message.recipient_email)
      )
      |> Repo.exists?()

    active_contact? and not suppressed?
  end

  defp next_attempt_number(message_id) do
    (from(a in DeliveryAttempt, where: a.message_id == ^message_id)
     |> Repo.aggregate(:max, :attempt_number) || 0) + 1
  end

  defp stale_claim?(nil, _job_claim_token), do: false
  defp stale_claim?(claim_token, claim_token), do: false
  defp stale_claim?(_claim_token, _job_claim_token), do: true

  defp provider_name(%Message{} = message) do
    message = Repo.preload(message, sender: :shared_sender)

    case message.sender do
      %{config: %{type: type}} when is_binary(type) -> type
      _ -> "unknown"
    end
  end

  defp record_first_attempt(nil, _started_at), do: :ok

  defp record_first_attempt(campaign_id, started_at) do
    from(c in Campaign,
      where: c.id == ^campaign_id and is_nil(c.first_attempt_at),
      update: [set: [first_attempt_at: ^started_at, updated_at: ^started_at]]
    )
    |> Repo.update_all([])

    :ok
  end

  defp record_uncertain_audit(%Message{campaign_id: nil}, _attempt), do: :ok

  defp record_uncertain_audit(message, attempt) do
    %{
      campaign_id: message.campaign_id,
      campaign_snapshot_id: message.campaign_snapshot_id,
      event: "delivery_uncertain",
      metadata: %{
        "message_id" => message.id,
        "attempt_id" => attempt.id,
        "attempt_number" => attempt.attempt_number
      }
    }
    |> AuditEvent.creation_changeset()
    |> Repo.insert!()
  end

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp receipt(%{id: receipt}) when is_binary(receipt), do: receipt
  defp receipt(receipt) when is_binary(receipt), do: receipt
  defp receipt(_), do: nil

  defp diagnostic_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp diagnostic_code(reason) when is_binary(reason), do: String.slice(reason, 0, 255)
  defp diagnostic_code(reason), do: reason |> inspect(limit: 10) |> String.slice(0, 255)

  defp now(), do: DateTime.utc_now(:second)
end
