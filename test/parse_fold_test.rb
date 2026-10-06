require File.expand_path('../helper', __FILE__)

class ParseFoldTest < Test::Unit::TestCase
  # Counts Match allocations so tests can prove that folding never builds
  # a Match tree.
  @match_allocations = 0

  class << self
    attr_accessor :match_allocations
  end

  module MatchAllocationCounter
    def initialize(*args)
      ParseFoldTest.match_allocations += 1
      super
    end
  end

  Match.prepend(MatchAllocationCounter)

  # Sums a comma-separated list of numbers.
  NumberSum = Grammar.new do
    root :sum

    rule :number do
      fold(/[0-9]+/) {|_, string| string.to_i }
    end

    rule :item do
      fold(all(',', :number)) {|children, _| children[1] }
    end

    rule :items do
      fold(zero_or_more(:item)) {|children, _| children }
    end

    rule :sum do
      fold(all(:number, :items)) {|children, _|
        children[0] + children[1].inject(0, :+)
      }
    end
  end

  # Evaluates arithmetic expressions with +, -, *, / and parentheses.
  Calculator = Grammar.new do
    root :expr

    rule :number do
      fold(/[0-9]+/) {|_, string| string.to_i }
    end

    rule :primary do
      any(:number, fold(all('(', :expr, ')')) {|children, _| children[1] })
    end

    rule :term do
      fold(all(:primary, fold(zero_or_more(any(
        fold(all('*', :primary)) {|children, _| [:*, children[1]] },
        fold(all('/', :primary)) {|children, _| [:/, children[1]] }
      ))) {|children, _| children })) {|children, _|
        children[1].inject(children[0]) {|acc, pair| acc.send(pair[0], pair[1]) }
      }
    end

    rule :expr do
      fold(all(:term, fold(zero_or_more(any(
        fold(all('+', :term)) {|children, _| [:+, children[1]] },
        fold(all('-', :term)) {|children, _| [:-, children[1]] }
      ))) {|children, _| children })) {|children, _|
        children[1].inject(children[0]) {|acc, pair| acc.send(pair[0], pair[1]) }
      }
    end
  end

  # The first alternative matches "a" and a number before failing on "b",
  # so parsing exercises backtracking with folded values in flight.
  Backtracking = Grammar.new do
    root :start

    rule :num do
      fold(/[0-9]+/) {|_, string| string.to_i }
    end

    rule :start do
      any(
        fold(all('a', :num, 'b')) {|children, _| [:first, children[1]] },
        fold(all('a', :num, 'c')) {|children, _| [:second, children[1]] }
      )
    end
  end

  def test_fold_sum_of_long_number_list
    numbers = (1..2000).map {|n| n * 3 }
    assert_equal(numbers.inject(0, :+), NumberSum.parse_fold(numbers.join(',')))
  end

  def test_fold_expression_evaluation
    assert_equal(14, Calculator.parse_fold('2+3*4'))
    assert_equal(20, Calculator.parse_fold('(2+3)*4'))
    assert_equal(5,  Calculator.parse_fold('10-2-3'))
    assert_equal(2,  Calculator.parse_fold('8/2/2'))
    assert_equal(1,  Calculator.parse_fold('7-(2*3)'))
  end

  def test_parse_fold_builds_no_match_tree
    input = (1..2000).map {|n| n * 3 }.join(',')

    ParseFoldTest.match_allocations = 0
    NumberSum.parse_fold(input)
    fold_allocations = ParseFoldTest.match_allocations
    assert_equal(0, fold_allocations)

    ParseFoldTest.match_allocations = 0
    match = NumberSum.parse(input)
    force_match_tree(match)
    parse_allocations = ParseFoldTest.match_allocations
    assert(parse_allocations > 1000,
      "expected parse to allocate many Match objects, got #{parse_allocations}")
  end

  def test_parse_fold_builds_no_match_tree_when_memoized
    input = (1..2000).map {|n| n * 3 }.join(',')

    ParseFoldTest.match_allocations = 0
    NumberSum.parse_fold(input, :memoize => true)
    assert_equal(0, ParseFoldTest.match_allocations)
  end

  def test_backtracking_values_are_not_committed
    assert_equal([:second, 7], Backtracking.parse_fold('a7c'))
  end

  def test_backtracking_values_are_not_committed_when_memoized
    assert_equal([:second, 7], Backtracking.parse_fold('a7c', :memoize => true))
  end

  def test_memoized_fold_caches_folded_values
    folds = 0
    folder = { :num => ->(_, string) { folds += 1; string.to_i } }

    input = MemoizedFoldingInput.new('a7c', folder)
    events = input.exec(Backtracking.rule(:start))

    assert_equal([:second, 7], input.values_for(events).last)
    assert_equal(1, folds)
    assert(input.cache_hits > 0, 'expected the memo cache to be hit')
  end

  def test_memoized_fold_matches_unmemoized
    input = '2+3*(4+5)-6/2'
    assert_equal(Calculator.parse_fold(input),
      Calculator.parse_fold(input, :memoize => true))
  end

  def test_cache_is_not_shared_between_folders
    as_value  = { :number => ->(_, string) { string.to_i } }
    as_length = { :number => ->(_, string) { string.length } }

    assert_equal(66, NumberSum.parse_fold('11,22,33',
      :memoize => true, :folder => as_value))
    assert_equal(6, NumberSum.parse_fold('11,22,33',
      :memoize => true, :folder => as_length))
  end

  def test_folder_option_overrides_declared_folds
    folder = { :number => ->(_, string) { string.to_i * 10 } }
    assert_equal(60, NumberSum.parse_fold('1,2,3', :folder => folder))
  end

  def test_parse_fold_with_root_option
    assert_equal(42, NumberSum.parse_fold('42', :root => :number))
  end

  def test_parse_fold_with_offset
    assert_equal(3, NumberSum.parse_fold('x1,2', :offset => 1))
  end

  def test_parse_fold_raises_on_failure
    assert_raise(ParseError) { NumberSum.parse_fold('1,2,x') }
  end

  def test_parse_fold_requires_consume_by_default
    assert_raise(ParseError) { NumberSum.parse_fold('1 2') }
    assert_equal(1, NumberSum.parse_fold('1 2', :consume => false))
  end

  def test_normal_parse_is_unaffected
    match = NumberSum.parse('1,2,3')
    assert_equal(Match, match.class)
    assert_equal('1,2,3', match.string)
  end

  def test_fold_must_be_callable
    assert_raise(ArgumentError) { Rule.for('a').fold = 42 }
  end

private

  # Match trees are instantiated lazily, level by level, so the whole tree
  # must be traversed to force every Match object to be allocated.
  def force_match_tree(match)
    match.matches.each {|m| force_match_tree(m) }
  end
end
