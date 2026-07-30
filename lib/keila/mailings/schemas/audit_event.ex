defmodule Keila.Mailings.AuditEvent do
  use Keila.Schema, prefix: "mae"

  alias Keila.Mailings.{Campaign, CampaignSnapshot}

  schema "mailings_audit_events" do
    field :event, :string
    field :actor, :string, default: "system"
    field :metadata, :map, default: %{}

    belongs_to :campaign, Campaign, type: Campaign.Id
    belongs_to :campaign_snapshot, CampaignSnapshot, type: CampaignSnapshot.Id

    timestamps(updated_at: false)
  end

  def creation_changeset(struct \\ %__MODULE__{}, params) do
    struct
    |> cast(params, [:campaign_id, :campaign_snapshot_id, :event, :actor, :metadata])
    |> validate_required([:campaign_id, :event, :actor])
  end
end
