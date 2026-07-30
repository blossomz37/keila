defmodule KeilaWeb.PublicCampaignController do
  use KeilaWeb, :controller

  plug :fetch_campaign

  def show(conn, _params) do
    case conn.assigns.public_campaign do
      {:snapshot, %{archive_html: html}} when is_binary(html) ->
        conn |> put_resp_content_type("text/html") |> send_resp(200, html)

      {:snapshot, %{archive_text: text}} when is_binary(text) ->
        conn |> put_resp_content_type("text/plain") |> send_resp(200, text)

      {:legacy, campaign} ->
        render_legacy_campaign(conn, campaign)
    end
  end

  defp render_legacy_campaign(conn, campaign) do
    case Keila.Mailings.CampaignRenderer.render_preview(campaign) do
      %{valid?: true, html_body: html} when is_binary(html) ->
        conn |> put_resp_content_type("text/html") |> send_resp(200, html)

      %{valid?: true, text_body: text} when is_binary(text) ->
        conn |> put_resp_content_type("text/plain") |> send_resp(200, text)

      _ ->
        conn |> send_resp(404, "") |> halt()
    end
  end

  defp fetch_campaign(conn, _) do
    id = conn.params["id"]

    cond do
      snapshot = Keila.Mailings.get_public_campaign_snapshot(id) ->
        assign(conn, :public_campaign, {:snapshot, snapshot})

      campaign = Keila.Mailings.get_public_campaign(id) ->
        assign(conn, :public_campaign, {:legacy, campaign})

      true ->
        conn |> send_resp(404, "") |> halt()
    end
  end
end
