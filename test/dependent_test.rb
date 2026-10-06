require File.expand_path('../helper', __FILE__)

class DependentTest < Test::Unit::TestCase
  # A length-prefixed UTF-8 payload. The length prefix is interpreted as a
  # character count.
  CharPayload = Grammar.new do
    root :payload

    rule :length do
      ext(/[0-9]+/) { to_str.to_i }
    end

    rule :payload do
      bind(:length, :n) { |n| chars(n) }
    end
  end

  # A length-prefixed UTF-8 payload. The length prefix is interpreted as a
  # byte count.
  BytePayload = Grammar.new do
    root :payload

    rule :length do
      ext(/[0-9]+/) { to_str.to_i }
    end

    rule :payload do
      bind(:length, :n) { |n| bytes(n) }
    end
  end

  # A count-prefixed list of words.
  WordList = Grammar.new do
    root :list

    rule :count do
      ext(/[0-9]+/) { to_str.to_i }
    end

    rule :word do
      /[a-z]+/
    end

    rule :list do
      bind(:count, :n) { |n| rep(all(' ', :word), n, n) }
    end
  end

  # Nested bindings of the same name. The inner binding shadows the outer
  # one only for the duration of its own continuation.
  Shadow = Grammar.new do
    root :outer

    rule :num do
      ext(/[0-9]/) { to_str.to_i }
    end

    rule :outer do
      bind(:num, :n) do |n|
        all(
          bind(:num, :n) { |m| chars(m) },
          dependent(/ /) { |sp, env| chars(env[:n]) }
        )
      end
    end
  end

  # The first alternative binds :n and then fails, which must not leak the
  # binding into the environment seen by the second alternative.
  Rollback = Grammar.new do
    root :try

    rule :num do
      ext(/[0-9]/) { to_str.to_i }
    end

    rule :try do
      any(
        all(bind(:num, :n) { |n| chars(n) }, 'z'),
        dependent(:num) { |v, env| chars(env.fetch(:n, 1)) }
      )
    end
  end

  # Both alternatives parse the same prefix but bind different values to
  # :n, so the memoized result of :item at position 1 depends on the
  # binding environment.
  EnvSensitive = Grammar.new do
    root :s

    rule :item do
      dependent(/[a-z]/) { |v, env| chars(env[:n]) }
    end

    rule :s do
      any(
        all(bind(ext('x') { 2 }, :n) { |n| :item }, 'z'),
        all(bind(ext('x') { 3 }, :n) { |n| :item }, 'z')
      )
    end
  end

  def test_requires_block
    assert_raise(ArgumentError) { Dependent.new('a') }
  end

  def test_to_s
    rule = Dependent.new('a', :n) { 'b' }
    assert_equal('bind(n:"a")', rule.to_s)

    rule = Dependent.new(/[0-9]/) { 'b' }
    assert_equal('dependent(/[0-9]/)', rule.to_s)
  end

  def test_dependent_selects_next_rule_from_value
    rule = Dependent.new(/[ab]/) { |v| v * 2 }
    assert_equal(3, rule.test('aaa'))
    assert_nil(rule.test('abc'))
  end

  def test_char_length_prefix_with_utf8_payload
    match = CharPayload.parse('3你好世')
    assert_equal('3你好世', match.string)
    assert_equal('你好世', match.matches[1].to_s)
  end

  def test_char_length_prefix_memoized
    match = CharPayload.parse('3你好世', :memoize => true)
    assert_equal('你好世', match.matches[1].to_s)
  end

  def test_char_length_prefix_zero
    match = CharPayload.parse('0')
    assert_equal('0', match.string)
    assert_equal('', match.matches[1].to_s)
  end

  def test_byte_length_prefix_with_utf8_payload
    match = BytePayload.parse('9你好世')
    assert_equal('9你好世', match.string)
    assert_equal('你好世', match.matches[1].to_s)
  end

  def test_byte_length_prefix_memoized
    match = BytePayload.parse('9你好世', :memoize => true)
    assert_equal('你好世', match.matches[1].to_s)
  end

  def test_count_prefixed_list
    match = WordList.parse('3 apple banana cherry')
    assert_equal(%w< apple banana cherry >, match.captures(:word).map(&:to_s))
  end

  def test_count_prefixed_list_count_mismatch
    assert_raise(ParseError) { WordList.parse('2 apple banana cherry') }
  end

  def test_count_prefixed_list_memoized
    match = WordList.parse('3 apple banana cherry', :memoize => true)
    assert_equal(%w< apple banana cherry >, match.captures(:word).map(&:to_s))
  end

  def test_negative_count_rejected
    assert_raise(ArgumentError) { Chars.new(-1) }
    assert_raise(ArgumentError) { Bytes.new(-1) }
  end

  def test_over_limit_rejected
    # Only 3 characters remain, but the prefix demands 5.
    assert_raise(ParseError) { CharPayload.parse('5你好世') }
    # 你好 is only 6 bytes, but the prefix demands 9.
    assert_raise(ParseError) { BytePayload.parse('9你好') }
  end

  def test_over_limit_does_not_consume_input
    input = Input.new('abc')
    events = input.exec(Chars.new(5))
    assert_equal([], events)
    assert_equal(0, input.pos)

    events = input.exec(Bytes.new(4))
    assert_equal([], events)
    assert_equal(0, input.pos)
  end

  def test_nested_same_name_binding_does_not_pollute_outer
    # Outer binds n=2, inner binds n=1 and consumes one character. The
    # trailing dependent reads :n from the environment; it must see the
    # outer value (2), not the inner one (1).
    match = Shadow.parse('21X YZ')
    assert_equal('21X YZ', match.string)
  end

  def test_environment_visible_in_nested_bindings
    grammar = Grammar.new do
      root :outer

      rule :num do
        ext(/[0-9]/) { to_str.to_i }
      end

      rule :outer do
        bind(:num, :a) do |a, env|
          bind(:num, :b) do |b, env2|
            chars(env2[:a] + b)
          end
        end
      end
    end

    match = grammar.parse('12abc')
    assert_equal('12abc', match.string)
  end

  def test_environment_restored_after_failure
    # The first alternative binds n=2, consumes "ab", then fails on 'z'.
    # The second alternative must not see the stale :n binding, so it falls
    # back to a count of 1 and matches only "2a".
    match = Rollback.parse('2abc', :consume => false)
    assert_equal('2a', match.string)
  end

  def test_environment_restored_after_failure_memoized
    match = Rollback.parse('2abc', :consume => false, :memoize => true)
    assert_equal('2a', match.string)
  end

  def test_binding_stack_push_pop
    input = Input.new('abc')
    assert_equal({}, input.bindings)

    input.push_binding(:n, 1)
    input.push_binding(:n, 2)
    assert_equal(2, input.bindings[:n])

    input.pop_binding
    assert_equal(1, input.bindings[:n])

    input.pop_binding
    assert(!input.bindings.key?(:n))
  end

  def test_memoization_accounts_for_dependent_values
    # The first alternative binds n=2 and fails after :item; the second
    # binds n=3 and re-parses :item at the same position. A cache that
    # ignores the binding environment would replay the n=2 result and the
    # parse would fail.
    match = EnvSensitive.parse('xabcdz', :memoize => true)
    assert_equal('xabcdz', match.string)
  end

  def test_memoized_cache_hits_with_same_environment
    grammar = Grammar.new do
      root :s

      rule :num do
        ext(/[0-9]/) { to_str.to_i }
      end

      rule :s do
        bind(:num, :n) { |n| all(andp(chars(n)), chars(n)) }
      end
    end

    match = grammar.parse('3abc', :memoize => true)
    assert_equal('3abc', match.string)
    assert(match.input.cache_hits > 0)
  end

  def test_chars_equality
    assert_equal(Chars.new(2), Chars.new(2))
    assert_equal(Chars.new(2).hash, Chars.new(2).hash)
    assert_not_equal(Chars.new(2), Chars.new(3))
    assert_not_equal(Chars.new(2), Bytes.new(2))
  end

  def test_bytes_equality
    assert_equal(Bytes.new(2), Bytes.new(2))
    assert_equal(Bytes.new(2).hash, Bytes.new(2).hash)
    assert_not_equal(Bytes.new(2), Bytes.new(3))
  end

  def test_chars_to_citrus
    assert_equal('chars(3)', Chars.new(3).to_citrus)
    assert_equal('bytes(3)', Bytes.new(3).to_citrus)
  end
end
