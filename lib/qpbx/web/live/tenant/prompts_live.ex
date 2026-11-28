defmodule QPBX.Web.Tenant.PromptsLive do
  @moduledoc """
  Tenant admin: the prompt library. Recordings uploaded here (WAV or MP3, up to 5 MB) are
  played by IVRs, ring groups and the like; the system prompts listed beside them can be used
  the same way. Each can be listened to on the page.
  """
  use QPBX.Web, :live_view
  alias QPBX.Telephony

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Prompts"), name: "")
     |> allow_upload(:audio, accept: ~w(.mp3 .wav), max_entries: 1, max_file_size: 5_000_000)
     |> load()}
  end

  defp load(socket),
    do: assign(socket, prompts: Telephony.list_prompts(socket.assigns.current_scope))

  @impl true
  def handle_event("validate", %{"prompt" => %{"name" => name}}, socket),
    do: {:noreply, assign(socket, name: name)}

  # sobelow_skip ["Traversal.FileModule"]
  # The path is LiveView's own temporary upload file.
  def handle_event("upload", %{"prompt" => %{"name" => name}}, socket) do
    %{current_scope: scope, current_account: actor} = socket.assigns

    results =
      consume_uploaded_entries(socket, :audio, fn %{path: path}, _entry ->
        {:ok, Telephony.upload_prompt(scope, name, File.read!(path), actor)}
      end)

    socket =
      case results do
        [{:ok, p}] ->
          socket |> put_flash(:info, gettext("%{name} added.", name: p.name)) |> assign(name: "")

        [] ->
          put_flash(socket, :error, gettext("Choose a WAV or MP3 file."))

        [error] ->
          put_flash(socket, :error, error_text(error))
      end

    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    %{current_scope: scope, current_account: actor} = socket.assigns

    case Telephony.delete_prompt(scope, id, actor) do
      {:ok, p} ->
        {:noreply,
         socket |> put_flash(:info, gettext("%{name} removed.", name: p.name)) |> load()}

      _ ->
        {:noreply, load(socket)}
    end
  end

  defp error_text({:error, :not_audio}), do: gettext("That file is not WAV or MP3 audio.")
  defp error_text({:error, :too_large}), do: gettext("The file is larger than 5 MB.")

  defp error_text({:error, %Ecto.Changeset{errors: errors}}) do
    if Keyword.has_key?(errors, :name),
      do: gettext("Give it a name that is not used yet."),
      else: gettext("The prompt could not be saved.")
  end

  defp error_text(_), do: gettext("The prompt could not be saved.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      locale={@locale}
      current_account={@current_account}
      unread={assigns[:unread]}
      idle_timeout={@idle_timeout}
    >
      <.header>
        {gettext("Prompts")}
        <:subtitle>
          {gettext(
            "Recordings your menus and groups play to callers. Upload your own, or use the system prompts."
          )}
        </:subtitle>
      </.header>

      <.live_component
        module={PagedTable}
        id="prompts"
        rows={@prompts}
        search={& &1.name}
        placeholder={gettext("Search prompts")}
        empty={gettext("No recordings yet. Upload the first one below.")}
      >
        <:col :let={p} label={gettext("Name")}>
          <span class="font-medium">{p.name}</span>
          <span class="block text-xs text-muted">
            {String.upcase(p.format)} · {Float.round(p.size / 1_000_000, 1)} MB
          </span>
        </:col>
        <:col :let={p} label={gettext("Listen")}>
          <audio controls preload="none" class="h-8 max-w-56" src={~p"/app/prompts/#{p.id}/audio"}>
          </audio>
        </:col>
        <:action :let={p}>
          <.link
            phx-click="delete"
            phx-value-id={p.id}
            id={"delete-#{p.id}"}
            class="btn btn-ghost btn-xs text-error"
            data-confirm={gettext("Remove %{name}?", name: p.name)}
          >
            <.icon name="hero-trash" class="size-4" /> {gettext("Remove")}
          </.link>
        </:action>
      </.live_component>

      <.form for={%{}} as={:prompt} id="prompt-form" phx-change="validate" phx-submit="upload">
        <.section
          title={gettext("Upload a recording")}
          icon="hero-arrow-up-tray"
          hint={gettext("WAV or MP3, up to 5 MB. Short and clear works best for callers.")}
        >
          <div class="grid sm:grid-cols-2 gap-x-4 items-end">
            <.input
              name="prompt[name]"
              id="prompt_name"
              value={@name}
              label={gettext("Name (e.g. Main menu)")}
              required
            />
            <div class="mb-2">
              <.live_file_input upload={@uploads.audio} class="file-input w-full" />
            </div>
          </div>
          <p
            :for={err <- Enum.flat_map(@uploads.audio.entries, &upload_errors(@uploads.audio, &1))}
            class="text-error text-sm"
          >
            {upload_error(err)}
          </p>
        </.section>
        <.form_actions>
          <.button variant="primary">
            <.icon name="hero-arrow-up-tray" class="size-4" /> {gettext("Upload")}
          </.button>
        </.form_actions>
      </.form>

      <.section
        title={gettext("System prompts")}
        icon="hero-speaker-wave"
        hint={gettext("English recordings that come with Q-PBX.")}
      >
        <.live_component module={PagedTable} id="system-prompts" rows={system_rows()}>
          <:col :let={s} label={gettext("Says")}><span class="font-medium">{s.label}</span></:col>
          <:col :let={s} label={gettext("Listen")}>
            <audio
              controls
              preload="none"
              class="h-8 max-w-56"
              src={~p"/app/prompts/system?#{%{path: s.id}}"}
            >
            </audio>
          </:col>
        </.live_component>
      </.section>
    </Layouts.app>
    """
  end

  defp system_rows,
    do: for({path, key} <- Telephony.system_prompts(), do: %{id: path, label: system_label(key)})

  @doc false
  def system_label(:thank_you_for_calling), do: gettext("Thank you for calling")
  def system_label(:thank_you), do: gettext("Thank you")
  def system_label(:one_moment), do: gettext("One moment please")
  def system_label(:hold_while_contacted), do: gettext("Please hold while the party is contacted")
  def system_label(:hold_connect), do: gettext("Please hold while we connect your call")

  def system_label(:stay_on_line),
    do: gettext("Stay on the line, your call will be answered shortly")

  def system_label(:thank_you_for_holding), do: gettext("Thank you for holding")
  def system_label(:longer_hold_times), do: gettext("Hold times are longer than usual")
  def system_label(:being_transferred), do: gettext("Your call is being transferred")
  def system_label(:enter_extension), do: gettext("Enter the extension")
  def system_label(:enter_extension_pound), do: gettext("Enter the extension followed by pound")
  def system_label(:invalid_entry), do: gettext("That was an invalid entry")
  def system_label(:invalid_extension), do: gettext("Invalid extension, please try again")
  def system_label(:try_again), do: gettext("Please try again")
  def system_label(:repeat_options), do: gettext("To repeat these options")
  def system_label(:previous_menu), do: gettext("To return to the previous menu")
  def system_label(:other_options), do: gettext("For other options")
  def system_label(:sorry), do: gettext("I'm sorry")
  def system_label(:goodbye), do: gettext("Goodbye")

  defp upload_error(:too_large), do: gettext("The file is larger than 5 MB.")
  defp upload_error(:not_accepted), do: gettext("Only MP3 or WAV files.")
  defp upload_error(_), do: gettext("The file could not be uploaded.")
end
