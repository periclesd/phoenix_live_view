defmodule Phoenix.LiveView.HTMLTokenizer do
  @moduledoc false
  @space_chars '\s\t\f'
  @name_stop_chars @space_chars ++ '>/=\r\n'

  defmodule ParseError do
    defexception [:file, :line, :column, :message]

    @impl true
    def message(exception) do
      location =
        exception.file
        |> Path.relative_to_cwd()
        |> format_file_line_column(exception.line, exception.column)

      "#{location} #{exception.message}"
    end

    # Use Exception.format_file_line_column/4 instead when support
    # for Elixir < v1.11 is removed.
    def format_file_line_column(file, line, column, suffix \\ "") do
      cond do
        is_nil(file) -> ""
        is_nil(line) or line == 0 -> "#{file}:#{suffix}"
        is_nil(column) or column == 0 -> "#{file}:#{line}:#{suffix}"
        true -> "#{file}:#{line}:#{column}:#{suffix}"
      end
    end
  end

  def tokenize(text, opts \\ []) do
    file = Keyword.get(opts, :file, "nofile")
    line = Keyword.get(opts, :line, 1)
    column = Keyword.get(opts, :column, 1)
    indentation = Keyword.get(opts, :indentation, 0)

    state = %{file: file, column_offset: indentation + 1, braces: []}
    handle_text(text, line, column, [], [], state)
  end

  ## handle_text

  defp handle_text("\r\n" <> rest, line, _column, buffer, acc, state) do
    handle_text(rest, line + 1, state.column_offset, ["\r\n" | buffer], acc, state)
  end

  defp handle_text("\n" <> rest, line, _column, buffer, acc, state) do
    handle_text(rest, line + 1, state.column_offset, ["\n" | buffer], acc, state)
  end

  defp handle_text("<!doctype" <> rest, line, column, buffer, acc, state) do
    handle_doctype(rest, line, column + 9, ["<!doctype" | buffer], acc, state)
  end

  defp handle_text("<!DOCTYPE" <> rest, line, column, buffer, acc, state) do
    handle_doctype(rest, line, column + 9, ["<!DOCTYPE" | buffer], acc, state)
  end

  defp handle_text("<!--" <> rest, line, column, buffer, acc, state) do
    case handle_comment(rest, line, column + 4, ["<!--" | buffer], state) do
      {:ok, new_rest, new_live, new_column, new_buffer} ->
        handle_text(new_rest, new_live, new_column, new_buffer, acc, state)

      {:error, message} ->
        raise ParseError, file: state.file, line: line, column: column, message: message
    end
  end

  defp handle_text("</" <> rest, line, column, buffer, acc, state) do
    handle_tag_close(rest, line, column + 2, text_to_acc(buffer, acc), state)
  end

  defp handle_text("<" <> rest, line, column, buffer, acc, state) do
    handle_tag_open(rest, line, column + 1, text_to_acc(buffer, acc), state)
  end

  defp handle_text(<<c::utf8, rest::binary>>, line, column, buffer, acc, state) do
    handle_text(rest, line, column + 1, [<<c::utf8>> | buffer], acc, state)
  end

  defp handle_text(<<>>, _line, _column, buffer, acc, _state) do
    ok(text_to_acc(buffer, acc))
  end

  ## handle_doctype

  defp handle_doctype(<<?>, rest::binary>>, line, column, buffer, acc, state) do
    handle_text(rest, line, column + 1, [?> | buffer], acc, state)
  end

  defp handle_doctype("\r\n" <> rest, line, _column, buffer, acc, state) do
    handle_doctype(rest, line + 1, state.column_offset, ["\r\n" | buffer], acc, state)
  end

  defp handle_doctype("\n" <> rest, line, _column, buffer, acc, state) do
    handle_doctype(rest, line + 1, state.column_offset, ["\n" | buffer], acc, state)
  end

  defp handle_doctype(<<c::utf8, rest::binary>>, line, column, buffer, acc, state) do
    handle_doctype(rest, line, column + 1, [<<c::utf8>> | buffer], acc, state)
  end

  ## handle_comment

  defp handle_comment("\r\n" <> rest, line, _column, buffer, state) do
    handle_comment(rest, line + 1, state.column_offset, ["\r\n" | buffer], state)
  end

  defp handle_comment("\n" <> rest, line, _column, buffer, state) do
    handle_comment(rest, line + 1, state.column_offset, ["\n" | buffer], state)
  end

  defp handle_comment("-->" <> rest, line, column, buffer, _state) do
    {:ok, rest, line, column + 3, ["-->" | buffer]}
  end

  defp handle_comment(<<c::utf8, rest::binary>>, line, column, buffer, state) do
    handle_comment(rest, line, column + 1, [<<c::utf8>> | buffer], state)
  end

  defp handle_comment(<<>>, line, column, _buffer, state) do
    message = "expected closing `-->` for comment"
    raise ParseError, file: state.file, line: line, column: column, message: message
  end

  ## handle_tag_open

  defp handle_tag_open(text, line, column, acc, state) do
    case handle_tag_name(text, column, []) do
      {:ok, name, new_column, rest} ->
        acc = [{:tag_open, name, [], %{line: line, column: column - 1}} | acc]
        handle_maybe_tag_open_end(rest, line, new_column, acc, state)

      {:warn, name, new_column, rest, message} ->
        acc = [{:tag_open, name, [], %{line: line, column: column - 1}} | acc]
        warn(message, state.file, line)
        handle_maybe_tag_open_end(rest, line, new_column, acc, state)

      {:error, message} ->
        raise ParseError, file: state.file, line: line, column: column, message: message
    end
  end

  ## handle_tag_close

  defp handle_tag_close(text, line, column, acc, state) do
    case handle_tag_name(text, column, []) do
      {:ok, name, new_column, rest} ->
        acc = [{:tag_close, name, %{line: line, column: column - 2}} | acc]
        handle_tag_close_end(rest, line, new_column, acc, state)

      {:warn, name, new_column, rest, message} ->
        acc = [{:tag_open, name, [], %{line: line, column: column - 1}} | acc]
        warn(message, state.file, line)
        handle_maybe_tag_open_end(rest, line, new_column, acc, state)

      {:error, message} ->
        raise ParseError, file: state.file, line: line, column: column, message: message
    end
  end

  defp handle_tag_close_end(">" <> rest, line, column, acc, state) do
    handle_text(rest, line, column + 1, [], acc, state)
  end

  defp handle_tag_close_end(_text, line, column, _acc, state) do
    message = "expected closing `>`"
    raise ParseError, file: state.file, line: line, column: column, message: message
  end

  ## handle_tag_name

  defp handle_tag_name(<<c::utf8, _rest::binary>>, _column, _buffer = [])
       when c in @name_stop_chars do
    {:error, "expected tag name"}
  end

  defp handle_tag_name(<<c::utf8, _rest::binary>> = text, column, buffer)
       when c in @name_stop_chars do
    tag_name = buffer_to_string(buffer)

    case tag_name do
      <<first::utf8, rest::binary>> when first in ?a..?z ->
        if downcase?(rest) do
          {:ok, tag_name, column, text}
        else
          message = "expected tag name containing only lowercase chars, got: #{tag_name}"
          {:warn, tag_name, column, text, message}
        end

      _ ->
        {:ok, tag_name, column, text}
    end
  end

  defp handle_tag_name(<<c::utf8, rest::binary>>, column, buffer) do
    handle_tag_name(rest, column + 1, [<<c::utf8>> | buffer])
  end

  ## handle_maybe_tag_open_end

  defp handle_maybe_tag_open_end("\r\n" <> rest, line, _column, acc, state) do
    handle_maybe_tag_open_end(rest, line + 1, state.column_offset, acc, state)
  end

  defp handle_maybe_tag_open_end("\n" <> rest, line, _column, acc, state) do
    handle_maybe_tag_open_end(rest, line + 1, state.column_offset, acc, state)
  end

  defp handle_maybe_tag_open_end(<<c::utf8, rest::binary>>, line, column, acc, state)
       when c in @space_chars do
    handle_maybe_tag_open_end(rest, line, column + 1, acc, state)
  end

  defp handle_maybe_tag_open_end("/>" <> rest, line, column, acc, state) do
    acc = reverse_attrs(acc)
    handle_text(rest, line, column + 2, [], put_self_close(acc), state)
  end

  defp handle_maybe_tag_open_end(">" <> rest, line, column, acc, state) do
    acc = reverse_attrs(acc)
    handle_text(rest, line, column + 1, [], acc, state)
  end

  defp handle_maybe_tag_open_end("{" <> rest, line, column, acc, state) do
    handle_root_attribute(rest, line, column + 1, acc, state)
  end

  defp handle_maybe_tag_open_end(<<>>, line, column, _acc, state) do
    message = "expected closing `>` or `/>`"
    raise ParseError, file: state.file, line: line, column: column, message: message
  end

  defp handle_maybe_tag_open_end(text, line, column, acc, state) do
    handle_attribute(text, line, column, acc, state)
  end

  ## handle_attribute

  defp handle_attribute(text, line, column, acc, state) do
    case handle_attr_name(text, column, []) do
      {:ok, name, new_column, rest} ->
        acc = put_attr(acc, name)
        handle_maybe_attr_value(rest, line, new_column, acc, state)

      {:error, message} ->
        raise ParseError, file: state.file, line: line, column: column, message: message
    end
  end

  ## handle_root_attribute

  defp handle_root_attribute(text, line, column, acc, state) do
    case handle_interpolation(text, line, column, [], state) do
      {:ok, value, new_line, new_column, rest, state} ->
        acc = put_attr(acc, :root, {:expr, value, %{line: line, column: column}})
        handle_maybe_tag_open_end(rest, new_line, new_column, acc, state)

      {:error, message, line, column} ->
        raise ParseError, file: state.file, line: line, column: column, message: message
    end
  end

  ## handle_attr_name

  defp handle_attr_name(<<c::utf8, _rest::binary>>, _column, [])
       when c in @name_stop_chars do
    {:error, "expected attribute name"}
  end

  defp handle_attr_name(<<c::utf8, _rest::binary>> = text, column, buffer)
       when c in @name_stop_chars do
    {:ok, buffer_to_string(buffer), column, text}
  end

  defp handle_attr_name(<<c::utf8, rest::binary>>, column, buffer) do
    handle_attr_name(rest, column + 1, [<<c::utf8>> | buffer])
  end

  ## handle_maybe_attr_value

  defp handle_maybe_attr_value("\r\n" <> rest, line, _column, acc, state) do
    handle_maybe_attr_value(rest, line + 1, state.column_offset, acc, state)
  end

  defp handle_maybe_attr_value("\n" <> rest, line, _column, acc, state) do
    handle_maybe_attr_value(rest, line + 1, state.column_offset, acc, state)
  end

  defp handle_maybe_attr_value(<<c::utf8, rest::binary>>, line, column, acc, state)
       when c in @space_chars do
    handle_maybe_attr_value(rest, line, column + 1, acc, state)
  end

  defp handle_maybe_attr_value("=" <> rest, line, column, acc, state) do
    handle_attr_value_begin(rest, line, column + 1, acc, state)
  end

  defp handle_maybe_attr_value(text, line, column, acc, state) do
    handle_maybe_tag_open_end(text, line, column, acc, state)
  end

  ## handle_attr_value_begin

  defp handle_attr_value_begin("\r\n" <> rest, line, _column, acc, state) do
    handle_attr_value_begin(rest, line + 1, state.column_offset, acc, state)
  end

  defp handle_attr_value_begin("\n" <> rest, line, _column, acc, state) do
    handle_attr_value_begin(rest, line + 1, state.column_offset, acc, state)
  end

  defp handle_attr_value_begin(<<c::utf8, rest::binary>>, line, column, acc, state)
       when c in @space_chars do
    handle_attr_value_begin(rest, line, column + 1, acc, state)
  end

  defp handle_attr_value_begin("\"" <> rest, line, column, acc, state) do
    handle_attr_value_double_quote(rest, line, column + 1, [], acc, state)
  end

  defp handle_attr_value_begin("'" <> rest, line, column, acc, state) do
    handle_attr_value_single_quote(rest, line, column + 1, [], acc, state)
  end

  defp handle_attr_value_begin("{" <> rest, line, column, acc, state) do
    handle_attr_value_as_expr(rest, line, column + 1, acc, state)
  end

  defp handle_attr_value_begin(_text, line, column, _acc, state) do
    message = "expected attribute value or expression after `=`"
    raise ParseError, file: state.file, line: line, column: column, message: message
  end

  ## handle_attr_value_double_quote

  defp handle_attr_value_double_quote("\r\n" <> rest, line, _column, buffer, acc, state) do
    column = state.column_offset
    handle_attr_value_double_quote(rest, line + 1, column, ["\r\n" | buffer], acc, state)
  end

  defp handle_attr_value_double_quote("\n" <> rest, line, _column, buffer, acc, state) do
    column = state.column_offset
    handle_attr_value_double_quote(rest, line + 1, column, ["\n" | buffer], acc, state)
  end

  defp handle_attr_value_double_quote("\"" <> rest, line, column, buffer, acc, state) do
    value = buffer_to_string(buffer)
    acc = put_attr_value(acc, {:string, value, %{delimiter: ?"}})

    handle_maybe_tag_open_end(rest, line, column + 1, acc, state)
  end

  defp handle_attr_value_double_quote(<<c::utf8, rest::binary>>, line, column, buffer, acc, state) do
    handle_attr_value_double_quote(rest, line, column + 1, [<<c::utf8>> | buffer], acc, state)
  end

  defp handle_attr_value_double_quote(<<>>, line, column, _buffer, _acc, state) do
    message = "expected closing `\"` for attribute value"
    raise ParseError, file: state.file, line: line, column: column, message: message
  end

  ## handle_attr_value_single_quote

  defp handle_attr_value_single_quote("\r\n" <> rest, line, _column, buffer, acc, state) do
    column = state.column_offset
    handle_attr_value_single_quote(rest, line + 1, column, ["\r\n" | buffer], acc, state)
  end

  defp handle_attr_value_single_quote("\n" <> rest, line, _column, buffer, acc, state) do
    column = state.column_offset
    handle_attr_value_single_quote(rest, line + 1, column, ["\n" | buffer], acc, state)
  end

  defp handle_attr_value_single_quote("'" <> rest, line, column, buffer, acc, state) do
    value = buffer_to_string(buffer)
    acc = put_attr_value(acc, {:string, value, %{delimiter: ?'}})

    handle_maybe_tag_open_end(rest, line, column + 1, acc, state)
  end

  defp handle_attr_value_single_quote(<<c::utf8, rest::binary>>, line, column, buffer, acc, state) do
    handle_attr_value_single_quote(rest, line, column + 1, [<<c::utf8>> | buffer], acc, state)
  end

  defp handle_attr_value_single_quote(<<>>, line, column, _buffer, _acc, state) do
    message = "expected closing `'` for attribute value"
    raise ParseError, file: state.file, line: line, column: column, message: message
  end

  ## handle_attr_value_as_expr

  defp handle_attr_value_as_expr(text, line, column, acc, %{braces: []} = state) do
    case handle_interpolation(text, line, column, [], state) do
      {:ok, value, new_line, new_column, rest, state} ->
        acc = put_attr_value(acc, {:expr, value, %{line: line, column: column}})
        handle_maybe_tag_open_end(rest, new_line, new_column, acc, state)

      {:error, message, line, column} ->
        raise ParseError, file: state.file, line: line, column: column, message: message
    end
  end

  ## handle_interpolation

  defp handle_interpolation("\r\n" <> rest, line, _column, buffer, state) do
    handle_interpolation(rest, line + 1, state.column_offset, ["\r\n" | buffer], state)
  end

  defp handle_interpolation("\n" <> rest, line, _column, buffer, state) do
    handle_interpolation(rest, line + 1, state.column_offset, ["\n" | buffer], state)
  end

  defp handle_interpolation("}" <> rest, line, column, buffer, %{braces: []} = state) do
    value = buffer_to_string(buffer)
    {:ok, value, line, column + 1, rest, state}
  end

  defp handle_interpolation(~S(\}) <> rest, line, column, buffer, state) do
    handle_interpolation(rest, line, column + 2, [~S(\}) | buffer], state)
  end

  defp handle_interpolation(~S(\{) <> rest, line, column, buffer, state) do
    handle_interpolation(rest, line, column + 2, [~S(\{) | buffer], state)
  end

  defp handle_interpolation("}" <> rest, line, column, buffer, state) do
    {_pos, state} = pop_brace(state)
    handle_interpolation(rest, line, column + 1, ["}" | buffer], state)
  end

  defp handle_interpolation("{" <> rest, line, column, buffer, state) do
    state = push_brace(state, {line, column})
    handle_interpolation(rest, line, column + 1, ["{" | buffer], state)
  end

  defp handle_interpolation(<<c::utf8, rest::binary>>, line, column, buffer, state) do
    handle_interpolation(rest, line, column + 1, [<<c::utf8>> | buffer], state)
  end

  defp handle_interpolation(<<>>, line, column, _buffer, _state) do
    {:error, "expected closing `}` for expression", line, column}
  end

  ## helpers

  defp ok(acc), do: Enum.reverse(acc)

  defp buffer_to_string(buffer) do
    IO.iodata_to_binary(Enum.reverse(buffer))
  end

  defp text_to_acc([], acc), do: acc
  defp text_to_acc(buffer, acc), do: [{:text, buffer_to_string(buffer)} | acc]

  defp put_attr([{:tag_open, name, attrs, meta} | acc], attr, value \\ nil) do
    attrs = [{attr, value} | attrs]
    [{:tag_open, name, attrs, meta} | acc]
  end

  defp put_attr_value([{:tag_open, name, [{attr, _value} | attrs], meta} | acc], value) do
    attrs = [{attr, value} | attrs]
    [{:tag_open, name, attrs, meta} | acc]
  end

  defp reverse_attrs([{:tag_open, name, attrs, meta} | acc]) do
    attrs = Enum.reverse(attrs)
    [{:tag_open, name, attrs, meta} | acc]
  end

  defp put_self_close([{:tag_open, name, attrs, meta} | acc]) do
    meta = Map.put(meta, :self_close, true)
    [{:tag_open, name, attrs, meta} | acc]
  end

  defp push_brace(state, pos) do
    %{state | braces: [pos | state.braces]}
  end

  defp pop_brace(%{braces: [pos | braces]} = state) do
    {pos, %{state | braces: braces}}
  end

  defp downcase?(<<c, _::binary>>) when c in ?A..?Z, do: false
  defp downcase?(<<_, rest::binary>>), do: downcase?(rest)
  defp downcase?(<<>>), do: true

  defp warn(message, file, line) do
    stacktrace = Macro.Env.stacktrace(%{__ENV__ | file: file, line: line, module: nil})
    IO.warn(message, stacktrace)
  end
end
