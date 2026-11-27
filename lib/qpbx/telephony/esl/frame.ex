defmodule QPBX.Telephony.ESL.Frame do
  @moduledoc """
  FreeSWITCH event socket framing: a block of `Name: value` header lines ended by a blank line,
  then `Content-Length` bytes of body. `parse/1` takes a buffer and returns the complete frames
  and the rest. Event bodies (`text/event-json`) are decoded to a map.
  """

  @type frame :: %{headers: %{String.t() => String.t()}, body: binary() | map() | nil}

  @spec parse(binary()) :: {[frame()], binary()}
  def parse(buffer), do: parse(buffer, [])

  defp parse(buffer, acc) do
    case :binary.split(buffer, "\n\n") do
      [head, rest] ->
        headers = headers(head)

        case Integer.parse(Map.get(headers, "Content-Length", "0")) do
          {len, ""} when byte_size(rest) >= len ->
            <<body::binary-size(len), rest::binary>> = rest
            parse(rest, [%{headers: headers, body: body(headers, body)} | acc])

          {_len, ""} ->
            {Enum.reverse(acc), buffer}

          _ ->
            # A malformed length: drop the frame rather than wait forever.
            parse(rest, acc)
        end

      [_incomplete] ->
        {Enum.reverse(acc), buffer}
    end
  end

  defp headers(head) do
    for line <- String.split(head, "\n", trim: true),
        [k, v] <- [String.split(line, ": ", parts: 2)],
        into: %{} do
      {k, URI.decode(v)}
    end
  end

  defp body(_headers, ""), do: nil

  defp body(%{"Content-Type" => "text/event-json"}, body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      {:error, _} -> body
    end
  end

  defp body(_headers, body), do: body

  @doc "A command: its first line and optional extra header lines, ended by a blank line."
  def command(line, headers \\ []) do
    [line, "\n", Enum.map(headers, fn {k, v} -> [k, ": ", v, "\n"] end), "\n"]
  end
end
