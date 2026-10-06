# encoding: UTF-8

require File.expand_path('../helper', __FILE__)

class DependentTest < Test::Unit::TestCase
  grammar :DependentProtocol do
    rule :utf8_frame do
      dependent(bind(:byte_length, :length)) do |length|
        all(bytes(length), :end)
      end
    end

    rule :character_frame do
      dependent(bind(:character_length, :length)) do |length|
        all(chars(length), :end)
      end
    end

    rule :byte_length, :expr do
      all(/[0-9]+/, ' ') { first.to_s.to_i }
    end

    rule :character_length, :expr do
      all(/[0-9]+/, ' ') { first.to_s.to_i }
    end

    rule :end do
      '!'
    end
  end

  grammar :DependentList do
    rule :list do
      dependent(bind(:count, :count)) do |count|
        rep(:item, count, count)
      end
    end

    rule :count, :expr do
      all(/[0-9]+/, ' ') { first.to_s.to_i }
    end

    rule :item do
      all(/[a-z]+/, zero_or_one([" ", notp(/[0-9]/)])) {
        first.to_s
      }
    end
  end

  def test_utf8_byte_length_prefix
    match = DependentProtocol.parse("2 ä!", :root => :utf8_frame)
    assert_equal("2 ä!", match)
  end

  def test_utf8_character_length_prefix
    match = DependentProtocol.parse("1 ä!", :root => :character_frame)
    assert_equal("1 ä!", match)
  end

  def test_negative_length_is_rejected
    length = Length.new(-1, :characters)
    assert_nil(length.test("abc"))
  end

  def test_length_beyond_remaining_input_is_rejected
    length = Length.new(4, :characters)
    assert_nil(length.test("abc"))
  end

  def test_byte_length_that_splits_utf8_is_rejected
    length = Length.new(1, :bytes)
    assert_nil(length.test("ä"))
  end

  def test_quantity_prefix_selects_repetition_count
    match = DependentList.parse("2 abc def", :memoize => true)
    assert_equal("2 abc def", match)
  end

  def test_too_few_items_is_rejected
    assert_nil(DependentList.rule(:list).test("2 abc"))
  end

  def test_local_bindings_are_restored
    grammar = Grammar.new do
      rule :root do
        all(
          dependent(bind(:size, :size)) { |size| chars(size) },
          dependent(Rule.for("")) { |_, bindings|
            raise if bindings.key?(:size)
            ""
          }
        )
      end

      rule :size do
        all(/[0-9]+/, ' ') { first.to_s.to_i }
      end
    end

    match = grammar.parse("2 ab")
    assert_equal("2 ab", match)
  end

  def test_failed_choice_restores_bindings
    grammar = Grammar.new do
      rule :root do
        all(
          any(bind("1", :value), bind("2", :value)),
          dependent(Rule.for("")) { |_, bindings|
            bindings[:value] == "1" ? "a" : "b"
          }
        )
      end
    end

    match = grammar.parse("2b")
    assert_equal("2b", match)
  end

  def test_memoization_uses_dependent_bindings
    grammar = Grammar.new do
      rule :root do
        any(
          all("x", bind("b", :kind) { to_s }, :same),
          all(bind("b", :kind) { to_s }, :same)
        )
      end

      rule :marker do
        any("a", "b")
      end

      rule :same do
        dependent(Rule.for("")) { |_, bindings|
          bindings[:kind]
        }
      end
    end

    match = grammar.parse("bb", :memoize => true)
    assert_equal("bb", match)
  end
end
