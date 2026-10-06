require File.expand_path('../helper', __FILE__)

# Counts Match allocations so tests can prove that parse_fold computes its
# result without ever building a tree of Match objects.
module MatchAllocationCounter
  def new(*)
    self.allocations += 1
    super
  end

  def allocations
    @allocations ||= 0
  end

  attr_writer :allocations
end

Citrus::Match.singleton_class.send(:prepend, MatchAllocationCounter)

class ParseFoldTest < Test::Unit::TestCase
  Numbers = Grammar.new do
    rule :list, all(:number, zero_or_more(all(',', :number)))
    rule :number, /[0-9]+/
    root :list
  end

  NUMBER_FOLDS = {
    :number => lambda {|children, string| string.to_i },
    :list   => lambda {|children, string| children.flatten.grep(Integer).inject(0, :+) }
  }

  Calc = Grammar.new do
    rule :expr, all(:term, zero_or_more(all(any('+', '-'), :term)))
    rule :term, all(:factor, zero_or_more(all(any('*', '/'), :factor)))
    rule :factor, any(:number, :paren)
    rule :paren, all('(', :expr, ')')
    rule :number, /[0-9]+/
    root :expr
  end

  CALC_FOLDS = {
    :number => lambda {|children, string| string.to_i },
    :paren  => lambda {|children, string| children[1] },
    :expr   => lambda {|children, string|
      children[1].inject(children[0]) {|acc, (op, val)| op == '+' ? acc + val : acc - val }
    },
    :term   => lambda {|children, string|
      children[1].inject(children[0]) {|acc, (op, val)| op == '*' ? acc * val : acc / val }
    }
  }

  Backtrack = Grammar.new do
    rule :list, all(:thing, zero_or_more(all(',', :thing)))
    rule :thing, any(all(:num, '!'), :num)
    rule :num, /[0-9]+/
    root :list
  end

  grammar :FoldLetterA do
    rule :top do
      any(:three_as, :two_as, :one_a)
    end

    rule :three_as do
      rep(:one_a, 3, 3)
    end

    rule :two_as do
      rep(:one_a, 2, 2)
    end

    rule :one_a do
      "a"
    end
  end

  def number_list(n)
    (1..n).to_a.join(',')
  end

  def test_fold_long_number_list_sum
    input = number_list(5000)
    expected = (1..5000).inject(0, :+)

    assert_equal expected, Numbers.parse_fold(input, NUMBER_FOLDS)
    assert_equal expected, Numbers.parse_fold(input, NUMBER_FOLDS, :memoize => true)
  end

  def test_fold_sum_matches_match_tree_sum
    input = number_list(100)
    folded = Numbers.parse_fold(input, NUMBER_FOLDS)

    match = Numbers.parse(input)
    tree_sum = match.captures[:number].map {|m| m.to_s.to_i }.inject(0, :+)

    assert_equal tree_sum, folded
  end

  def test_fold_does_not_allocate_match_nodes
    input = number_list(2000)

    Citrus::Match.allocations = 0
    Numbers.parse_fold(input, NUMBER_FOLDS)
    assert_equal 0, Citrus::Match.allocations

    # A regular parse followed by tree traversal allocates one Match per
    # node in the parse tree.
    Citrus::Match.allocations = 0
    Numbers.parse(input).captures(:number)
    assert Citrus::Match.allocations > 2000
  end

  def test_fold_expression_evaluation
    assert_equal 14, Calc.parse_fold('2+3*4', CALC_FOLDS)
    assert_equal 20, Calc.parse_fold('(2+3)*4', CALC_FOLDS)
    assert_equal 2, Calc.parse_fold('100/10/5', CALC_FOLDS)
    assert_equal 7, Calc.parse_fold('10-3', CALC_FOLDS)

    expression = '(2+3)*4-10/2+((6*7)-(8/4))'
    assert_equal eval(expression), Calc.parse_fold(expression, CALC_FOLDS)
    assert_equal eval(expression), Calc.parse_fold(expression, CALC_FOLDS, :memoize => true)
  end

  def test_fold_expression_does_not_allocate_match_nodes
    Citrus::Match.allocations = 0
    Calc.parse_fold('(2+3)*4-10/2+((6*7)-(8/4))', CALC_FOLDS)
    assert_equal 0, Citrus::Match.allocations
  end

  def test_backtracked_branches_do_not_commit_values
    folded = []
    folds = {
      :num   => lambda {|children, string| folded << string; string.to_i },
      :thing => lambda {|children, string| x = children[0]; x.is_a?(Array) ? x[0] : x },
      :list  => lambda {|children, string| children[0] + children[1].inject(0) {|sum, pair| sum + pair[1] } }
    }

    # For "4" and "6" the first alternative of +thing+ matches +num+ and
    # then fails on '!', so the folded values of those branches must be
    # discarded instead of committed to the enclosing list.
    assert_equal 18, Backtrack.parse_fold('3!,4,5!,6', folds)
    assert_equal %w[ 3 4 4 5 6 6 ], folded

    # With memoization the folded values of +num+ are replayed from the
    # cache instead of being recomputed, with the same result.
    folded.clear
    assert_equal 18, Backtrack.parse_fold('3!,4,5!,6', folds, :memoize => true)
    assert_equal %w[ 3 4 5 6 ], folded
  end

  def test_fold_cache_is_not_shared_between_folder_sets
    input = '2,3,4'

    product_folds = {
      :number => lambda {|children, string| string.to_i },
      :list   => lambda {|children, string| children.flatten.grep(Integer).inject(1, :*) }
    }

    assert_equal 9, Numbers.parse_fold(input, NUMBER_FOLDS, :memoize => true)
    assert_equal 24, Numbers.parse_fold(input, product_folds, :memoize => true)
    assert_equal 9, Numbers.parse_fold(input, NUMBER_FOLDS, :memoize => true)
  end

  def test_folder_set_on_rule_is_used_by_default
    grammar = Grammar.new do
      rule :number, /[0-9]+/
      root :number
    end

    grammar.rule(:number).folder = lambda {|children, string| string.to_i * 2 }

    assert_equal 10, grammar.parse_fold('5')
    # Folders passed to parse_fold take precedence over folders on rules.
    assert_equal 5, grammar.parse_fold('5', :number => lambda {|children, string| string.to_i })
  ensure
    grammar.rule(:number).folder = nil
  end

  def test_default_folding
    # Terminals fold to their matched string, repeats to an array of their
    # children, and other rules to a single child or an array of children.
    assert_equal ['1', [[',', '2']]], Numbers.parse_fold('1,2')
    assert_equal 'a', FoldLetterA.rule(:top).parse_fold('a')
  end

  def test_parse_fold_raises_parse_error_unless_input_is_consumed
    assert_raise(ParseError) { Numbers.parse_fold('1,2,x', NUMBER_FOLDS) }
    assert_equal 3, Numbers.parse_fold('1,2,x', NUMBER_FOLDS, :consume => false)
  end

  def test_parse_fold_with_offset
    assert_equal 3, Numbers.parse_fold('ab1,2', NUMBER_FOLDS, :offset => 2)
  end

  def test_grammar_parse_fold_with_root_option
    assert_equal 42, Numbers.parse_fold('42', NUMBER_FOLDS, :root => :number)
  end

  def test_memoized_fold_input_cache_hits
    input = MemoizedFoldInput.new('a')
    events = FoldEvents.new({}, 'a')
    input.exec(FoldLetterA.rule(:top), events)

    assert_equal 3, input.cache_hits
    assert_equal 'a', events.value
  end

  def test_parse_still_returns_a_match
    match = Numbers.parse('1,2,3')
    assert_kind_of Match, match
    assert_equal '1,2,3', match.to_s
    assert_equal 3, match.captures[:number].size
  end
end
