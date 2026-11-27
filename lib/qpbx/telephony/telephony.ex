defmodule QPBX.Telephony do
  @moduledoc """
  Public API of the telephony area: call control. FreeSWITCH asks for a dialplan
  (`dialplan_xml/1`, served by the web area at `/internal/freeswitch/dialplan`) and is told to
  park every call; one process per call then drives it over the event socket. See
  `lib/qpbx/telephony/README.md`.
  """
  use Boundary,
    deps: [QPBX.Repo, QPBX.Core, QPBX.Events, QPBX.Storage, QPBX.Notify],
    exports: [Router, Dialplan, Cache, Calls, Usage, Fraud, Admission]

  alias QPBX.Telephony.{Calls, Dialplan}
  alias QPBX.Telephony.ESL.Connection

  @doc "The dialplan XML for a FreeSWITCH request (park under call control)."
  defdelegate dialplan_xml(params), to: Dialplan, as: :xml

  @doc "Whether the event socket to FreeSWITCH is up (health check)."
  def connected?, do: Process.whereis(Connection) != nil and Connection.connected?()

  ## Voicemail (tenant admins; see QPBX.Telephony.Voicemail)

  alias QPBX.Telephony.Voicemail
  defdelegate mailbox(scope, ext_id), to: Voicemail
  defdelegate change_mailbox(mailbox, attrs \\ %{}), to: Voicemail
  defdelegate save_mailbox(scope, ext_id, attrs, actor), to: Voicemail
  defdelegate delete_mailbox(scope, ext_id, actor), to: Voicemail
  defdelegate list_voicemails(scope), to: Voicemail, as: :list_messages
  defdelegate voicemail_audio(scope, id), to: Voicemail, as: :message_audio
  defdelegate save_voicemail(scope, id, actor), to: Voicemail, as: :mark_saved
  defdelegate delete_voicemail(scope, id, actor), to: Voicemail, as: :delete_message
  defdelegate greetings(scope, ext_id), to: Voicemail
  defdelegate greeting_kinds(), to: Voicemail.Greeting, as: :kinds
  defdelegate put_greeting(scope, ext_id, kind, audio, actor), to: Voicemail
  defdelegate delete_greeting(scope, ext_id, kind, actor), to: Voicemail
  defdelegate voicemail_counts(tenant_id \\ nil), to: Voicemail, as: :counts

  ## Fraud protection (platform admins)

  alias QPBX.Telephony.Fraud
  defdelegate fraud_settings(), to: Fraud, as: :settings
  defdelegate change_fraud_settings(settings, attrs \\ %{}), to: Fraud, as: :change_settings
  defdelegate update_fraud_settings(attrs, actor), to: Fraud, as: :update_settings
  defdelegate list_fraud_blocks(), to: Fraud, as: :list_blocks
  defdelegate lift_fraud_block(id, actor), to: Fraud, as: :lift

  @doc "The password FreeSWITCH must send with dialplan requests."
  def curl_password, do: Application.get_env(:qpbx, __MODULE__, [])[:curl_password]

  @doc "Calls in progress."
  defdelegate active_calls(), to: Calls, as: :count

  @doc "The supervision tree of call control (started by the application)."
  def child_spec(_) do
    # The event socket only where FreeSWITCH runs (config `esl: true`, production).
    esl? = Application.get_env(:qpbx, __MODULE__, [])[:esl] == true

    children =
      [
        {Registry, keys: :unique, name: QPBX.Telephony.Registry},
        {Registry, keys: :duplicate, name: QPBX.Telephony.InUse},
        # Call admission's concurrency counts (joined by call processes).
        {Registry, keys: :duplicate, name: QPBX.Telephony.Active},
        QPBX.Telephony.Fraud,
        {DynamicSupervisor, name: QPBX.Telephony.CallSupervisor, strategy: :one_for_one},
        QPBX.Telephony.Cache
      ] ++ if(esl?, do: [Connection], else: [])

    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_one, name: QPBX.Telephony.Supervisor]]}
    }
  end
end
