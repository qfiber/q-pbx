defmodule QPBX.Web.Api.ParityTest do
  @moduledoc """
  Anything a person can do in the portal, code can do through the API (spec). Every
  `handle_event` of every portal page must be mapped here to an existing `/v1` route, or be
  listed as form-only or personal. A new portal action without an API route fails this test.
  """
  use ExUnit.Case, async: true

  # Page events that only change the form on screen.
  @ui_only ~w(validate validate_class validate_emergency validate_device validate_greeting
              validate_channel dismiss hide_secret edit cancel open refresh filter)

  # A signed-in person's own sessions: an API key is not a person.
  @personal %{
    "account/sessions_live" => ~w(revoke revoke_others),
    # A person's own bell and settings: an API key is not a person.
    "account/notifications_live" => ~w(read read_all save_settings)
  }

  @parity %{
    "account/api_keys_live" => %{
      "save" => "POST /v1/api-keys",
      "revoke" => "DELETE /v1/api-keys/:id"
    },
    "platform/admins_live" => %{
      "add" => "POST /v1/platform-admins",
      "setup_link" => "POST /v1/platform-admins/:id/setup-link",
      "sign_out" => "POST /v1/platform-admins/:id/sign-out"
    },
    "platform/audit_live" => %{"filter" => "GET /v1/audit"},
    "account/notifications_live" => %{"acknowledge" => "POST /v1/alerts/:id/acknowledge"},
    "account/alerts_live" => %{
      "acknowledge" => "POST /v1/alerts/:id/acknowledge",
      "resolve" => "POST /v1/alerts/:id/resolve",
      "resend" => "POST /v1/notifications/:id/resend",
      "test" => "POST /v1/alerts/test",
      "add_channel" => "POST /v1/alert-channels",
      "toggle_channel" => "PATCH /v1/alert-channels/:id",
      "delete_channel" => "DELETE /v1/alert-channels/:id",
      "mandatory" => "PUT /v1/alert-rules"
    },
    "platform/dids_live" => %{
      "save" => "POST /v1/numbers",
      "assign" => "PATCH /v1/numbers/:id",
      "delete" => "DELETE /v1/numbers/:id"
    },
    "platform/firewall_live" => %{
      "save" => "POST /v1/firewall",
      "delete" => "DELETE /v1/firewall/:id"
    },
    "platform/fraud_live" => %{
      "save" => "PATCH /v1/fraud",
      "lift" => "DELETE /v1/fraud/blocks/:id"
    },
    "platform/numbering_live" => %{
      "save_rule" => "PUT /v1/number-format",
      "add_class" => "POST /v1/number-classes",
      "delete_class" => "DELETE /v1/number-classes/:id",
      "add_emergency" => "POST /v1/emergency-routes",
      "delete_emergency" => "DELETE /v1/emergency-routes/:id"
    },
    "platform/plans_live" => %{"save" => ["POST /v1/plans", "PATCH /v1/plans/:id"]},
    "platform/protection_live" => %{
      "save" => "PATCH /v1/protection",
      "lift" => "DELETE /v1/protection/bans/:key"
    },
    "platform/tenant_live" => %{
      "save" => "PATCH /v1/tenants/:id",
      "add_admin" => "POST /v1/tenants/:tenant_id/users",
      "setup_link" => "POST /v1/tenants/:tenant_id/users/:id/setup-link",
      "sign_out" => "POST /v1/tenants/:tenant_id/users/:id/sign-out"
    },
    "platform/tenants_live" => %{"save" => "POST /v1/tenants"},
    "platform/trunks_live" => %{
      "save" => ["POST /v1/trunks", "PATCH /v1/trunks/:id"],
      "delete" => "DELETE /v1/trunks/:id"
    },
    "tenant/calls_live" => %{"search" => "GET /v1/calls"},
    "tenant/extension_live" => %{
      "save" => "PATCH /v1/extensions/:id",
      "add_device" => "POST /v1/extensions/:extension_id/devices",
      "reset_device" => "POST /v1/devices/:id/reset-password",
      "delete_device" => "DELETE /v1/devices/:id",
      "delete" => "DELETE /v1/extensions/:id"
    },
    "tenant/extensions_live" => %{"save" => "POST /v1/extensions"},
    "tenant/mailbox_live" => %{
      "save" => "PUT /v1/extensions/:extension_id/mailbox",
      "upload_greeting" => "PUT /v1/extensions/:extension_id/greetings/:kind",
      "delete_greeting" => "DELETE /v1/extensions/:extension_id/greetings/:kind"
    },
    "tenant/my_extension_live" => %{
      "save" => "PATCH /v1/extensions/:id",
      "heard" => "POST /v1/voicemails/:id/save",
      "delete_voicemail" => "DELETE /v1/voicemails/:id",
      "call" => "POST /v1/calls"
    },
    "tenant/number_format_live" => %{
      "save" => "PUT /v1/number-format",
      "reset" => "DELETE /v1/number-format"
    },
    "tenant/numbers_live" => %{"save" => "PUT /v1/numbers/:id/destination"},
    "tenant/office_ips_live" => %{
      "save" => "POST /v1/office-ips",
      "delete" => "DELETE /v1/office-ips/:id"
    },
    "tenant/routes_live" => %{
      "save" => ["POST /v1/routes", "PATCH /v1/routes/:id"],
      "delete" => "DELETE /v1/routes/:id"
    },
    "tenant/users_live" => %{
      "invite" => "POST /v1/users",
      "set_extension" => "PATCH /v1/users/:id",
      "set_role" => "PATCH /v1/users/:id",
      "setup_link" => "POST /v1/users/:id/setup-link",
      "sign_out" => "POST /v1/users/:id/sign-out",
      "delete" => "DELETE /v1/users/:id"
    },
    "tenant/webhooks_live" => %{"save" => "POST /v1/webhooks"},
    "tenant/webhook_live" => %{
      "save" => "PATCH /v1/webhooks/:id",
      "toggle" => "PATCH /v1/webhooks/:id",
      "rotate" => "POST /v1/webhooks/:id/rotate-secret",
      "delete" => "DELETE /v1/webhooks/:id",
      "resend" => "POST /v1/webhook-deliveries/:id/resend"
    },
    "tenant/voicemail_live" => %{
      "save" => "POST /v1/voicemails/:id/save",
      "delete" => "DELETE /v1/voicemails/:id"
    }
  }

  # The portal's own downloads have API equivalents too.
  @downloads ["GET /v1/calls/export", "POST /v1/voicemails/:id/audio-link"]

  defp routes do
    for r <- Phoenix.Router.routes(QPBX.Web.Router),
        into: MapSet.new(),
        do: "#{r.verb |> to_string() |> String.upcase()} #{r.path}"
  end

  test "every portal action has an API route" do
    root = Path.expand("../../../../lib/qpbx/web/live", __DIR__)
    routes = routes()

    actions =
      for file <- Path.wildcard(Path.join(root, "*/*.ex")),
          page = file |> Path.relative_to(root) |> Path.rootname(),
          [_, event] <- Regex.scan(~r/handle_event\("([a-z_]+)"/, File.read!(file)),
          event not in @ui_only,
          event not in Map.get(@personal, page, []),
          route <- List.wrap(get_in(@parity, [page, event]) || "unmapped"),
          uniq: true,
          do: {"#{page} #{event}", route}

    assert length(actions) > 50
    assert for({action, route} <- actions, route not in routes, do: "#{action}: #{route}") == []
  end

  test "the portal's downloads have API routes" do
    assert Enum.reject(@downloads, &(&1 in routes())) == []
  end
end
