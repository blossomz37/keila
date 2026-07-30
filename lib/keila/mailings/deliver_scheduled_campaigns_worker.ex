defmodule Keila.Mailings.DeliverScheduledCampaignsWorker do
  use Oban.Worker, queue: :campaign_scheduler
  alias Keila.Mailings

  def perform(%Oban.Job{}) do
    Mailings.get_campaigns_to_be_delivered(DateTime.utc_now())
    |> Enum.each(fn c ->
      Mailings.start_scheduled_campaign(c.id)
    end)

    :ok
  end
end
