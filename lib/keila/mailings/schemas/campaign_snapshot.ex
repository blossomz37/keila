defmodule Keila.Mailings.CampaignSnapshot do
  use Keila.Schema, prefix: "mcs"

  alias Keila.Mailings.Campaign
  alias Keila.Templates.Template

  schema "mailings_campaign_snapshots" do
    field :source_revision, :integer
    field :snapshot_sequence, :integer
    field :idempotency_key, :string
    field :render_input, :map
    field :audience_filter, :map
    field :renderer_version, :string
    field :content_sha256, :string
    field :audience_count, :integer
    field :archive_slug, :string
    field :archive_html, :string
    field :archive_text, :string
    field :frozen_at, :utc_datetime
    field :canceled_at, :utc_datetime

    belongs_to :campaign, Campaign, type: Campaign.Id

    timestamps()
  end

  @fields [
    :campaign_id,
    :source_revision,
    :snapshot_sequence,
    :idempotency_key,
    :render_input,
    :audience_filter,
    :renderer_version,
    :content_sha256,
    :audience_count,
    :archive_slug,
    :archive_html,
    :archive_text,
    :frozen_at
  ]

  def creation_changeset(struct \\ %__MODULE__{}, params) do
    struct
    |> cast(params, @fields)
    |> validate_required([
      :campaign_id,
      :source_revision,
      :snapshot_sequence,
      :idempotency_key,
      :render_input,
      :audience_filter,
      :renderer_version,
      :content_sha256,
      :audience_count,
      :archive_slug,
      :frozen_at
    ])
    |> unique_constraint([:campaign_id, :snapshot_sequence],
      name: :mailings_campaign_snapshots_campaign_sequence_index
    )
    |> unique_constraint(:archive_slug)
    |> unique_constraint([:campaign_id, :idempotency_key],
      name: :mailings_campaign_snapshots_campaign_idempotency_index
    )
  end

  def cancel_changeset(snapshot = %__MODULE__{}, canceled_at) do
    change(snapshot, canceled_at: canceled_at)
  end

  def to_campaign(%__MODULE__{render_input: %{"campaign" => campaign_data} = render_input}) do
    settings_data = Map.fetch!(campaign_data, "settings")
    template = to_template(render_input["template"])

    %Campaign{
      id: campaign_data["id"],
      project_id: campaign_data["project_id"],
      subject: campaign_data["subject"],
      text_body: campaign_data["text_body"],
      text_content: campaign_data["text_content"],
      html_body: campaign_data["html_body"],
      html_content: campaign_data["html_content"],
      json_body: campaign_data["json_body"],
      mjml_body: campaign_data["mjml_body"],
      mjml_content: campaign_data["mjml_content"],
      preview_text: campaign_data["preview_text"],
      data: campaign_data["data"],
      public_link_enabled: campaign_data["public_link_enabled"],
      template: template,
      settings: %Campaign.Settings{
        type: enum_atom(settings_data["type"]),
        enable_wysiwyg: settings_data["enable_wysiwyg"],
        do_not_track: settings_data["do_not_track"]
      }
    }
  end

  defp to_template(nil), do: nil

  defp to_template(data) do
    %Template{
      id: data["id"],
      name: data["name"],
      type: enum_atom(data["type"]),
      styles: data["styles"],
      assigns: data["assigns"],
      mjml_body: data["mjml_body"],
      html_body: data["html_body"],
      text_body: data["text_body"]
    }
  end

  defp enum_atom(value) when is_atom(value), do: value
  defp enum_atom(value) when is_binary(value), do: String.to_existing_atom(value)
end
