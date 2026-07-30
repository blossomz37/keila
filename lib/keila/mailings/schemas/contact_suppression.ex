defmodule Keila.Mailings.ContactSuppression do
  use Keila.Schema, prefix: "cs"

  alias Keila.Contacts.Contact
  alias Keila.Projects.Project

  schema "contacts_suppressions" do
    field :email_identity, :string
    field :reason, :string
    field :source, :string
    field :provider_ref, :string
    field :ended_at, :utc_datetime

    belongs_to :project, Project, type: Project.Id
    belongs_to :contact, Contact, type: Contact.Id

    timestamps()
  end

  def creation_changeset(struct \\ %__MODULE__{}, params) do
    struct
    |> cast(params, [
      :project_id,
      :contact_id,
      :email_identity,
      :reason,
      :source,
      :provider_ref
    ])
    |> update_change(:email_identity, &normalize_identity/1)
    |> validate_required([:project_id, :email_identity, :reason, :source])
    |> unique_constraint([:project_id, :email_identity],
      name: :contacts_suppressions_active_identity_index
    )
  end

  defp normalize_identity(email), do: email |> String.trim() |> String.downcase()
end
