defmodule Keila.Mailings.StaleDeliveryAttemptsWorker do
  use Oban.Worker, queue: :system, max_attempts: 1

  alias Keila.Mailings.Delivery

  @impl true
  def perform(%Oban.Job{args: args}) do
    stale_after_seconds = Map.get(args, "stale_after_seconds", 300)
    Delivery.mark_stale_attempts_uncertain(stale_after_seconds)
    :ok
  end
end
