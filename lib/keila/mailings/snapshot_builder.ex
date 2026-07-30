defmodule Keila.Mailings.SnapshotBuilder do
  @moduledoc false

  alias Keila.Contacts.Contact
  alias Keila.Mailings.{Campaign, CampaignRenderer}

  @renderer_version "keila-hardened-v1"

  def build(campaign = %Campaign{}, audience_filter) do
    archive_contact = %Contact{
      id: "archive",
      email: "archive@example.invalid",
      first_name: nil,
      last_name: nil,
      data: %{}
    }

    archive = CampaignRenderer.render_preview(campaign, archive_contact)
    render_input = render_input(campaign)

    {:ok,
     %{
       render_input: render_input,
       audience_filter: audience_filter,
       renderer_version: @renderer_version,
       content_sha256: content_sha256(render_input),
       archive_slug: random_slug(),
       archive_html: if(archive.valid?, do: archive.html_body),
       archive_text: if(archive.valid?, do: archive.text_body)
     }}
  end

  def recipient_snapshot(contact = %Contact{}) do
    %{
      "id" => contact.id,
      "email" => contact.email,
      "first_name" => contact.first_name,
      "last_name" => contact.last_name,
      "data" => contact.data || %{}
    }
  end

  def contact_from_recipient_snapshot(snapshot) when is_map(snapshot) do
    %Contact{
      id: snapshot["id"],
      email: snapshot["email"],
      first_name: snapshot["first_name"],
      last_name: snapshot["last_name"],
      data: snapshot["data"] || %{}
    }
  end

  defp render_input(campaign) do
    %{
      "campaign" => %{
        "id" => campaign.id,
        "project_id" => campaign.project_id,
        "subject" => campaign.subject,
        "text_body" => campaign.text_body,
        "text_content" => campaign.text_content,
        "html_body" => campaign.html_body,
        "html_content" => campaign.html_content,
        "json_body" => campaign.json_body,
        "mjml_body" => campaign.mjml_body,
        "mjml_content" => campaign.mjml_content,
        "preview_text" => campaign.preview_text,
        "data" => campaign.data,
        "public_link_enabled" => campaign.public_link_enabled,
        "settings" => %{
          "type" => to_string(campaign.settings.type),
          "enable_wysiwyg" => campaign.settings.enable_wysiwyg,
          "do_not_track" => campaign.settings.do_not_track
        }
      },
      "template" => template_input(campaign.template),
      "sender_identity" => sender_identity(campaign.sender)
    }
  end

  defp template_input(nil), do: nil

  defp template_input(template) do
    %{
      "id" => template.id,
      "name" => template.name,
      "type" => to_string(template.type),
      "styles" => template.styles,
      "assigns" => template.assigns,
      "mjml_body" => template.mjml_body,
      "html_body" => template.html_body,
      "text_body" => template.text_body
    }
  end

  defp sender_identity(nil), do: nil

  defp sender_identity(sender) do
    %{
      "id" => sender.id,
      "from_email" => sender.from_email,
      "from_name" => sender.from_name,
      "reply_to_email" => sender.reply_to_email,
      "reply_to_name" => sender.reply_to_name
    }
  end

  defp content_sha256(render_input) do
    render_input
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp random_slug do
    18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
