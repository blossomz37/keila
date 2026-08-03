defmodule Keila.Mailings.DeliveryAttempt do
  use Keila.Schema, prefix: "mda"

  alias Keila.Mailings.Message

  schema "mailings_delivery_attempts" do
    field :attempt_number, :integer
    field :claim_token, Ecto.UUID

    field :state, Ecto.Enum,
      values: [in_flight: 0, accepted: 1, rejected: 2, failed: 3, uncertain: 4]

    field :provider, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :provider_receipt, :string
    field :error_class, :string
    field :error_code, :string
    field :metadata, :map, default: %{}

    belongs_to :message, Message, type: Message.Id

    timestamps()
  end

  @creation_fields [
    :message_id,
    :attempt_number,
    :claim_token,
    :state,
    :provider,
    :started_at,
    :metadata
  ]

  def creation_changeset(struct \\ %__MODULE__{}, params) do
    struct
    |> cast(params, @creation_fields)
    |> validate_required([
      :message_id,
      :attempt_number,
      :claim_token,
      :state,
      :provider,
      :started_at
    ])
    |> unique_constraint([:message_id, :attempt_number],
      name: :mailings_delivery_attempts_message_number_index
    )
    |> unique_constraint(:message_id,
      name: :mailings_delivery_attempts_one_in_flight_index
    )
  end

  def terminal_changeset(attempt = %__MODULE__{}, params) do
    attempt
    |> cast(params, [
      :state,
      :completed_at,
      :provider_receipt,
      :error_class,
      :error_code,
      :metadata
    ])
    |> validate_required([:state, :completed_at])
    |> validate_inclusion(:state, [:accepted, :rejected, :failed, :uncertain])
  end
end
