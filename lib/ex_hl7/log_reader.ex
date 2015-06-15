defmodule HL7.LogReader do
  require Logger

  @type read_ret :: {:ok, state :: any} | {:error, reason :: any}
  @type callback :: (binary, pos_integer, state :: any -> read_ret)

  @spec read(Path.t, callback, state :: any) :: :ok | {:error, reason :: any}
  def read(filename, callback, state) do
    case :file.open(filename, [:read, :binary, :raw, {:read_ahead, 128 * 1024}]) do
      {:ok, file} ->
        try do
          read(file, callback, state, 1, [])
        after
          :file.close(file)
        end
      {:error, _reason} = error ->
        error
    end
  end

  defp read(file, callback, state, row, acc) do
    case :file.read_line(file) do
      {:ok, line} ->
        case match_segment_line(line) do
          {:match, segment} ->
            read(file, callback, state, row + 1, [segment | acc])
          :nomatch ->
            case acc do
              [] ->
                read(file,callback, state, row + 1, acc)
              _ ->
                message = IO.iodata_to_binary(Enum.reverse(acc))
                case callback.(message, row, state) do
                  {:continue, state} ->
                    read(file, callback, state, row + 1, [])
                  {:break, state} ->
                    {:ok, state}
                  {:error, _reason} = error ->
                    error
                end
            end
          :invalid ->
            Logger.warn("Invalid segment found on line #{row}:\n\n#{inspect line}")
            read(file, callback, state, row + 1, [])
        end
      :eof ->
        {:ok, state}
      {:error, _reason} = error ->
        error
    end
  end

  defp match_segment_line(<<segment_id :: binary-size(3), ?|, _rest :: binary>> = line) do
    if HL7.Lexer.valid_segment_id?(segment_id) do
      size = byte_size(line) - 3
      case line do
        <<segment :: binary-size(size), "\\r\n">> ->
          {:match, [unescape(segment), ?\r]}
        _ ->
          :invalid
      end   
    else
      :nomatch
    end
  end
  defp match_segment_line(_) do
    :nomatch
  end

  def unescape(text) do
    unescape_no_copy(text, byte_size(text), 0)
  end

  defp unescape_no_copy(text, size, index) when index < size do
    case text do
      <<head :: binary-size(index), ?\\, char, rest :: binary>> ->
        char = unescape_char(char)
        unescape_copy(rest, <<head :: binary, char>>)
      _ ->
        unescape_no_copy(text, size, index + 1)
    end
  end
  defp unescape_no_copy(text, _size, _index) do
    text
  end

  defp unescape_copy(<<?\\, char, rest :: binary>>, acc) do
    char = unescape_char(char)
    unescape_copy(rest, <<acc :: binary, char>>)
  end
  defp unescape_copy(<<char, rest :: binary>>, acc) do
    unescape_copy(rest, <<acc :: binary, char>>)
  end
  defp unescape_copy(<<>>, acc) do
    acc
  end

  defp unescape_char(?r), do: ?\r
  defp unescape_char(?n), do: ?\n
  defp unescape_char(?t), do: ?\t
  defp unescape_char(char), do: char

  @spec valid?(Path.t) :: boolean
  def valid?(filename) do
    case read(filename, &valid_message?/3, 0) do
      {:ok, error_count} ->
        Logger.debug("Found #{error_count} errors in `#{filename}`")
        true
      _ ->
        false
    end
  end

  defp valid_message?(text, row, error_count) do
    case HL7.read(text) do
      {:ok, _msg} ->
        {:continue, error_count}
      {:incomplete, _function} ->
        Logger.info("Found incomplete HL7 message on line #{row}:\n\n#{inspect text}")
        {:continue, error_count + 1}
      {:error, reason} ->
        Logger.warn("Failed to read HL7 message on line #{row}: #{inspect reason}\n\n#{inspect text}")
        {:continue, error_count + 1}
    end
  end
end