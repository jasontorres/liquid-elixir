defmodule Liquid.Parse do
  alias Liquid.{Block, Registers, Template, Variable}

  def tokenize(<<string::binary>>) do
    list =
      Liquid.template_parser()
      |> Regex.split(string, on: :all_but_first, trim: true)
      |> List.flatten()
      |> Enum.filter(&(&1 != ""))

    unless expressions_are_valid?(list) do
      raise Liquid.SyntaxError, message: "not match delimiters"
    end

    list
  end

  defp expressions_are_valid?(list) do
    Enum.all?(list, &Regex.match?(Liquid.valid_expression(), &1))
  end

  def parse("", %Template{} = template) do
    %{template | root: %Liquid.Block{name: :document}}
  end

  def parse(<<string::binary>>, %Template{} = template) do
    tokens = string |> tokenize
    name = tokens |> hd
    tag_name = parse_tag_name(name)
    tokens = parse_tokens(string, tag_name) || tokens
    { root, template } = parse(%Liquid.Block{name: :document}, tokens, [], template)
    %{ template | root: root }
  end

  def parse(%Block{name: :document} = block, [], accum, %Template{} = template) do
    { %{ block | nodelist: accum }, template }
  end

  def parse(%Block{name: :comment} = block, [h|t], accum, %Template{} = template) do
    cond do
      Regex.match?(~r/{%\s*endcomment\s*%}/, h) ->
        { %{ block | nodelist: accum }, t, template }
      Regex.match?(~r/{%\send.*?\s*$}/, h) ->
        raise "Unmatched block close: #{h}"
      true ->
        { result, rest, template } = try do
          parse_node(h, t, template)
        rescue
          # Ignore undefined tags inside comments
          RuntimeError -> { h, t, template }
        end
        parse(block, rest, accum ++ [result], template)
    end
  end

  def parse(%Block{name: name}, [], _, _) do
    raise "No matching end for block {% #{to_string(name)} %}"
  end

  def parse(%Block{name: name} = block, [h|t], accum, %Template{} = template) do
    endblock = "end" <> to_string(name)
    cond do
      Regex.match?(~r/{%\s*#{endblock}\s*%}/, h) ->
        { %{ block | nodelist: accum }, t, template }
      Regex.match?(~r/{%\send.*?\s*$}/, h) ->
        raise "Unmatched block close: #{h}"
      true ->
        { result, rest, template } = parse_node(h, t, template)
        parse(block, rest, accum ++ [result], template)
    end
  end

  defp parse_tokens(<<string::binary>>, tag_name) do
    case Registers.lookup(tag_name) do
      {mod, Liquid.Block} ->
        try do
          mod.tokenize(string)
        rescue
          UndefinedFunctionError -> nil
        end
      _ -> nil
    end
  end


  defp parse_tag_name(name) do
    case Regex.named_captures(Liquid.parser, name) do
      %{"tag" => tag_name, "variable" => _ } -> tag_name
      _ -> nil
    end
  end

  defp parse_node(<<name::binary>>, rest, %Template{}=template) do
    case Regex.named_captures(Liquid.parser, name) do
      %{"tag" => "", "variable" => markup} when is_binary(markup) ->
        { Variable.create(markup), rest, template }
      %{"tag" => markup, "variable" => ""} when is_binary(markup) ->
        parse_markup(markup, rest, template)
      nil -> { name, rest, template }
    end
  end

  defp parse_markup(markup, rest, template) do
    name = markup |> String.split(" ") |> hd
    case Registers.lookup(name) do
      { mod, Liquid.Block } ->
        parse_block(mod, markup, rest, template)
      { mod, Liquid.Tag } ->
        tag = Liquid.Tag.create(markup)
        { tag, template } = mod.parse(tag, template)
        { tag, rest, template }
      nil -> raise "unregistered tag: #{name}"
    end
  end

  defp parse_block(mod, markup, rest, template) do
    block = Liquid.Block.create(markup)
    { block, rest, template } = try do
        mod.parse(block, rest, [], template)
      rescue
        UndefinedFunctionError -> parse(block, rest, [], template)
      end
    { block, template } = mod.parse(block, template)
    { block, rest, template }
  end

end
