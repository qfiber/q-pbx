defmodule QPBX.Web.Tenant.MailboxLive do
  @moduledoc """
  Tenant admin: an extension's mailbox (PIN, email for new messages) and its greetings
  (MP3 or WAV uploads: unavailable, busy, temporary). Without a mailbox, unanswered calls end.
  """
  use QPBX.Web, :live_view
  alias QPBX.{Core, Telephony}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    ext = Core.get_extension!(socket.assigns.current_scope, id)

    {:ok,
     socket
     |> assign(page_title: gettext("Voicemail for %{number}", number: ext.number), ext: ext)
     |> allow_upload(:greeting, accept: ~w(.mp3 .wav), max_entries: 1, max_file_size: 5_000_000)
     |> load()}
  end

  defp load(socket) do
    %{current_scope: scope, ext: ext} = socket.assigns
    mb = Telephony.mailbox(scope, ext.id)

    assign(socket,
      mailbox: mb,
      form: to_form(Telephony.change_mailbox(mb), as: :mailbox),
      greetings: Telephony.greetings(scope, ext.id),
      greeting_form: to_form(%{"kind" => "unavailable"}, as: :greeting)
    )
  end

  @impl true
  def handle_event("save", %{"mailbox" => params}, socket) do
    %{current_scope: scope, current_account: actor, ext: ext} = socket.assigns
    params = if params["pin"] == "", do: Map.delete(params, "pin"), else: params

    case Telephony.save_mailbox(scope, ext.id, params, actor) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Saved.")) |> load()}

      {:error, cs} ->
        {:noreply, assign(socket, form: to_form(Map.put(cs, :action, :update), as: :mailbox))}
    end
  end

  def handle_event("validate_greeting", _params, socket), do: {:noreply, socket}

  # sobelow_skip ["Traversal.FileModule"]
  # The path is LiveView's own temporary upload file.
  def handle_event("upload_greeting", %{"greeting" => %{"kind" => kind}}, socket) do
    %{current_scope: scope, current_account: actor, ext: ext} = socket.assigns

    results =
      consume_uploaded_entries(socket, :greeting, fn %{path: path}, _entry ->
        {:ok, Telephony.put_greeting(scope, ext.id, kind, File.read!(path), actor)}
      end)

    socket =
      case results do
        [:ok] ->
          put_flash(socket, :info, gettext("Greeting saved."))

        [{:error, :not_audio}] ->
          put_flash(socket, :error, gettext("That file is not MP3 or WAV audio."))

        [{:error, _}] ->
          put_flash(socket, :error, gettext("The greeting could not be saved."))

        [] ->
          put_flash(socket, :error, gettext("Choose a file first."))
      end

    {:noreply, load(socket)}
  end

  def handle_event("delete_greeting", %{"kind" => kind}, socket) do
    %{current_scope: scope, current_account: actor, ext: ext} = socket.assigns
    :ok = Telephony.delete_greeting(scope, ext.id, kind, actor)
    {:noreply, socket |> put_flash(:info, gettext("Greeting removed.")) |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      locale={@locale}
      current_account={@current_account}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("Voicemail for %{number}", number: @ext.number)}
        <:subtitle>
          {gettext(
            "Callers leave a message when the extension is busy or does not answer. The owner dials *97 and the PIN to listen."
          )}
        </:subtitle>
        <:actions>
          <.link navigate={~p"/app/extensions/#{@ext.id}"} class="btn btn-ghost btn-sm">
            {gettext("Back to the extension")}
          </.link>
        </:actions>
      </.header>

      <.form for={@form} id="mailbox-form" phx-submit="save">
        <.input field={@form[:enabled]} type="checkbox" label={gettext("Voicemail on")} />
        <.input
          field={@form[:pin]}
          type="password"
          inputmode="numeric"
          autocomplete="new-password"
          dir="ltr"
          label={
            if @mailbox.id,
              do: gettext("New PIN (leave empty to keep it)"),
              else: gettext("PIN (4 to 10 digits)")
          }
        />
        <.input
          field={@form[:email]}
          type="email"
          dir="ltr"
          label={gettext("Email new messages to (optional)")}
        />
        <.input
          field={@form[:attach_audio]}
          type="checkbox"
          label={gettext("Attach the audio to the email")}
        />
        <.button variant="primary">{gettext("Save")}</.button>
      </.form>

      <div :if={@mailbox.id}>
        <h2 class="text-lg font-semibold mt-8">{gettext("Greetings")}</h2>
        <p class="text-sm opacity-70">
          {gettext(
            "Without a greeting callers hear a standard one with the extension number. A temporary greeting, while it exists, is played instead of the others."
          )}
        </p>
        <ul id="greetings" class="my-2">
          <li
            :for={kind <- Telephony.greeting_kinds()}
            :if={kind in @greetings}
            id={"greeting-#{kind}"}
          >
            {kind_label(kind)}
            <.link
              phx-click="delete_greeting"
              phx-value-kind={kind}
              id={"delete-greeting-#{kind}"}
              class="link ms-2"
            >
              {gettext("Remove")}
            </.link>
          </li>
        </ul>
        <.form
          for={@greeting_form}
          id="greeting-form"
          phx-change="validate_greeting"
          phx-submit="upload_greeting"
        >
          <.input
            field={@greeting_form[:kind]}
            type="select"
            label={gettext("Greeting")}
            options={Enum.map(Telephony.greeting_kinds(), &{kind_label(&1), &1})}
          />
          <.live_file_input upload={@uploads.greeting} class="file-input my-2" />
          <p
            :for={
              err <- Enum.flat_map(@uploads.greeting.entries, &upload_errors(@uploads.greeting, &1))
            }
            class="text-error"
          >
            {upload_error(err)}
          </p>
          <.button variant="primary">{gettext("Upload greeting")}</.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  defp kind_label("unavailable"), do: gettext("Not available")
  defp kind_label("busy"), do: gettext("Busy")
  defp kind_label("temporary"), do: gettext("Temporary")

  defp upload_error(:too_large), do: gettext("The file is larger than 5 MB.")
  defp upload_error(:not_accepted), do: gettext("Only MP3 or WAV files.")
  defp upload_error(_), do: gettext("The file could not be uploaded.")
end
