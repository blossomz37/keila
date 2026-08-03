defmodule KeilaWeb.PublicCampaignControllerTest do
  use KeilaWeb.ConnCase, async: true
  import Ecto.Query
  alias Keila.{Mailings, Repo}

  setup do
    group = insert!(:group)
    project = insert!(:project, group: group)
    {:ok, project: project}
  end

  describe "GET /archive/:id" do
    @describetag :public_campaign_controller

    test "returns 404 if public_link_enabled is not true", %{conn: conn, project: project} do
      campaign =
        insert!(:mailings_campaign,
          project_id: project.id,
          public_link_enabled: false,
          text_body: "Hello world!",
          sent_at: DateTime.utc_now(:second)
        )

      conn = get(conn, Routes.public_campaign_path(conn, :show, campaign.id))
      assert response(conn, 404)
    end

    test "returns 404 if campaign doesn't exist", %{conn: conn, project: project} do
      campaign = insert!(:mailings_campaign, project_id: project.id)
      Keila.Mailings.delete_campaign(campaign.id)

      conn = get(conn, Routes.public_campaign_path(conn, :show, campaign.id))
      assert response(conn, 404)
    end

    test "returns 404 if campaign has not been sent", %{conn: conn, project: project} do
      campaign =
        insert!(:mailings_campaign,
          project_id: project.id,
          public_link_enabled: true,
          text_body: "This campaign has not been sent yet",
          settings: %{type: :text},
          sent_at: nil
        )

      conn = get(conn, Routes.public_campaign_path(conn, :show, campaign.id))
      assert response(conn, 404)
    end

    test "renders text content of campaign type is :text", %{conn: conn, project: project} do
      campaign =
        insert!(:mailings_campaign,
          project_id: project.id,
          public_link_enabled: true,
          text_body: "This is a plain text campaign body.",
          settings: %{type: :text},
          sent_at: DateTime.utc_now(:second)
        )

      conn = get(conn, Routes.public_campaign_path(conn, :show, campaign.id))
      assert text_response(conn, 200) =~ "This is a plain text campaign body."
    end

    test "renders HTML preview if campaign type is :markdown", %{conn: conn, project: project} do
      campaign =
        insert!(:mailings_campaign,
          project_id: project.id,
          public_link_enabled: true,
          subject: "My Amazing Campaign",
          text_body: "# Hello World\n\nThis is **Markdown** content.",
          settings: %{type: :markdown},
          sent_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      conn = get(conn, Routes.public_campaign_path(conn, :show, campaign.id))
      assert response = html_response(conn, 200)
      assert response =~ "<title>My Amazing Campaign</title>"
      assert response =~ "<strong>Markdown</strong>"
    end

    test "returns 404 if there was a rendering error", %{conn: conn, project: project} do
      campaign =
        insert!(:mailings_campaign,
          project_id: project.id,
          public_link_enabled: true,
          text_body: "{{ 1 | divided_by, 0 }}",
          settings: %{
            type: :text
          },
          sent_at: DateTime.utc_now(:second)
        )

      conn = get(conn, Routes.public_campaign_path(conn, :show, campaign.id))
      assert response(conn, 404)
    end

    test "serves the frozen snapshot after the campaign row changes", %{
      conn: conn,
      project: project
    } do
      sender =
        insert!(:mailings_sender,
          project_id: project.id,
          config: %Mailings.Sender.Config{type: "test"}
        )

      insert!(:contact, project_id: project.id)

      campaign =
        insert!(:mailings_campaign,
          project_id: project.id,
          sender_id: sender.id,
          public_link_enabled: true,
          text_body: "Frozen archive body",
          settings: %{type: :text}
        )

      assert {:ok, _prepared} =
               Mailings.prepare_campaign(
                 campaign.id,
                 %{},
                 campaign.revision,
                 DateTime.utc_now(:second),
                 mode: :immediate
               )

      from(c in Mailings.Campaign,
        where: c.id == ^campaign.id,
        update: [set: [text_body: "Mutated campaign body"]]
      )
      |> Repo.update_all([])

      archived = get(conn, Routes.public_campaign_path(conn, :show, campaign.id))
      body = text_response(archived, 200)

      assert body =~ "Frozen archive body"
      refute body =~ "Mutated campaign body"
    end
  end
end
