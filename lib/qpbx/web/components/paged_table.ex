defmodule QPBX.Web.PagedTable do
  @moduledoc ~S"""
  A list in pages of 25, with an optional search box: one component for every long list in
  the portal. The page passes all its rows and the columns; the search and the page number
  live here (no handler in the page).

      <.live_component module={QPBX.Web.PagedTable} id="tenants" rows={@tenants}
        search={&(&1.name <> " " <> &1.sip_domain)} focus={@saved_id}>
        <:col :let={t} label="Name">{t.name}</:col>
        <:action :let={t}>...</:action>
      </.live_component>

  `search`: a row's searchable text (nil: no box). `focus`: an id to show (after a save the
  list opens on the page that holds it). `row_click` and `row_id` as in `table/1`; the table
  keeps the component's id, so `#tenants` is the table.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: QPBX.Web.Gettext
  import QPBX.Web.CoreComponents, only: [icon: 1, table: 1]
  alias QPBX.Web.Pager

  @impl true
  def mount(socket), do: {:ok, assign(socket, query: "", page: 1, focused: nil)}

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:search, fn -> nil end)
      |> assign_new(:placeholder, fn -> gettext("Search") end)
      |> assign_new(:row_click, fn -> nil end)
      |> assign_new(:row_id, fn -> nil end)
      |> assign_new(:action, fn -> [] end)
      |> assign_new(:empty, fn -> gettext("Nothing here yet.") end)

    {:ok, jump_to_focus(socket, assigns[:focus])}
  end

  # A new focus (a row just saved): the page that holds it, the search cleared.
  defp jump_to_focus(socket, nil), do: socket
  defp jump_to_focus(%{assigns: %{focused: id}} = socket, id), do: socket

  defp jump_to_focus(socket, id),
    do: assign(socket, query: "", focused: id, page: Pager.page_of(socket.assigns.rows, id))

  @impl true
  def handle_event("filter", %{"q" => q}, socket),
    do: {:noreply, assign(socket, query: q, page: 1)}

  def handle_event("page", %{"page" => n}, socket), do: {:noreply, assign(socket, page: n)}

  @impl true
  def render(assigns) do
    shown = matching(assigns.rows, assigns.search, assigns.query)
    assigns = assign(assigns, paged: Pager.paginate(shown, assigns.page))

    ~H"""
    <div class="space-y-3" id={"#{@id}-box"}>
      <form
        :if={@search && @rows != []}
        phx-change="filter"
        phx-submit="filter"
        phx-target={@myself}
        id={"#{@id}-search"}
        class="max-w-sm"
      >
        <label class="input w-full">
          <.icon name="hero-magnifying-glass" class="size-4 text-muted" />
          <input
            type="search"
            name="q"
            value={@query}
            placeholder={@placeholder}
            phx-debounce="200"
            autocomplete="off"
          />
        </label>
      </form>
      <div
        :if={@paged.total == 0}
        class="rounded-[12px] border border-dashed border-hairline bg-base-100/60 px-6 py-10 text-center text-sm text-muted"
        id={"#{@id}-empty"}
      >
        <.icon name="hero-inbox" class="size-6 mx-auto mb-2 opacity-60" />
        {if @query != "", do: gettext(~s(Nothing matches "%{q}".), q: @query), else: @empty}
      </div>
      {if @paged.total > 0,
        do:
          table(%{
            id: @id,
            rows: @paged.items,
            row_id: @row_id,
            row_click: @row_click,
            row_item: &Function.identity/1,
            col: @col,
            action: @action
          })}
      <Pager.pager id={"#{@id}-pages"} page={@paged} target={@myself} />
    </div>
    """
  end

  defp matching(rows, nil, _), do: rows
  defp matching(rows, _, ""), do: rows

  defp matching(rows, text, query) do
    q = query |> String.trim() |> String.downcase()
    Enum.filter(rows, &(&1 |> text.() |> String.downcase() |> String.contains?(q)))
  end
end
