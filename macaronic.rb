class Macaronic
  class Expression
    attr_accessor :method
    attr_accessor :arguments

    def initialize(method, arguments)
      @method = method
      @arguments = arguments
    end
  end

  class Assignment
    attr_accessor :scope
    attr_accessor :index
    attr_accessor :value

    def initialize(scope, index, value)
      @scope = scope
      @index = index
      @value = value
    end
  end

  class Local
    attr_accessor :type
    attr_accessor :label

    def initialize(type, label)
      @type = type
      @label = label
      @index = label
    end
  end

  class Frame
    attr_accessor :type
    attr_accessor :parameters
    attr_accessor :expressions

    def self.from_is(data)
      type = data[9]

      parameters = parameters_from_is(data[10], data[11])
      expressions = expressions_from_is(data[13], data[10])
      self.new(type, parameters, expressions, data[4][:stack_max])
    end

    # TODO support block_arguments
    def self.parameters_from_is(labels, info)
      if info.is_a? Integer
        params = labels.map.with_index do |l, i|
          if i < info
            Local.new(:simple_argument, labels[i])
          else
            Local.new(:simple_local, labels[i])
          end
        end
      else
        params = labels.map.with_index do |l, i|
          simple_bound = info[0]
          optional_bound = simple_bound + [info[1].length - 1, 0].max
          splat_bound = [optional_bound, info[4]].max
          post_simple_bound = splat_bound + info[2]
          if i < simple_bound
            Local.new(:simple_argument, labels[i])
          elsif i < optional_bound
            Local.new(:optional_argument, labels[i])
          elsif i < splat_bound
            Local.new(:splat_argument, labels[i])
          elsif i < post_simple_bound
            Local.new(:post_argument, labels[i])
          else
            Local.new(:simple_local, labels[i])
          end
        end
      end

      params.compact
    end

    def self.expressions_from_is(bytecodes, locals)
      expressions = []
      stack = []
      bytecodes.each do |inst|
        next if inst[0] == :trace
        # TODO: support ifs/whiles
        next if inst[0] == :jump
        stack << 0 if inst[0] == :putobject_OP_INT2FIX_O_0_C_ 
        stack << 1 if inst[0] == :putobject_OP_INT2FIX_O_0_C_ 
        stack << inst[1] if inst[0] == :putobject
        stack << :self if inst[0] == :putself

        stack << stack.last if inst[0] == :dup

        stack << self.pop_assignment(inst[2], inst[1], stack) if inst[0] == :setlocal
        stack << self.pop_assignment(1, inst[1], stack) if inst[0] == :setlocal_OP__WC__1
        stack << self.pop_assignment(0, inst[1], stack) if inst[0] == :setlocal_OP__WC__0

        stack << self.pop_expression(inst[1], stack) if inst[0] == :opt_send_simple
        stack << self.pop_expression(inst[1], stack) if inst[0] == :send
      end

      stack
    end

    def self.pop_expression(inst, stack)
      args = stack.pop(inst[:orig_argc])
      args.push self.from_is(inst[:blockptr]) if inst[:blockptr]
      Expression.new inst[:mid], args
    end

    def self.pop_assignment(depth, index, stack)
      value = stack.pop
      Assignment.new(depth, index, value)
    end

    def initialize(type, locals, expressions, stack_max)
      @type = type
      @locals = locals
      @expressions = expressions
      @stack_max = stack_max
    end

    def deepen_assigns
    end

    def method_to_assign(local)
    end

    def to_is
      [
        "YARVInstructionSequence/SimpleDataFormat",
        2, 1, 1,
        {
        arg_size: @parameters.is_size,
        local_size: self.is_local_size,
        stack_max: @stack_max,
      },
      "<compiled>", "<compiled>", nil, 1,
      @type,
      self.is_locals,
      @parameters.is_args,
      self.is_catch_table,
      self.is_bytecode,
      ]
    end
  end

  def self.splode(data)
    data = ISeq.of(data) if data.is_a? Proc
    data = data.to_a if data.is_a? ISeq

    Frame.from_is(data)
  end

  def self.load(frame)
    ISeq.load(frame.to_is)
  end

  def self.on(block)
    frame = self.splode(block)
    frame = yield frame
    self.load(frame)
  end
end

def do_block(&block)
  Macaronic.on(block){ |f| do_blockify(f) }
end

def do_blockify(f)
  back_assign_idxs = f.expressions.each_index.select { |i| f.expressions[i].method == :<= }
  first_idx = back_assign_idx[0]
  assign_line = f.expressions[first_idx]

  new_block_expressions = f.expressions[(first_idx + 1)..-1]
  f.expressions = f.expressions[0...first_idx]
  new_block_arg = Local.new(:simple_argument, assign_line.parameters[0].method)
  new_block = Frame.new(:block, [new_block_arg], new_block_expressions, f.stack_depth + 1)

  new_block.deepen_assigns
  new_block.method_to_local(new_block_arg)

  if back_assign_idxs.length > 1
    f.append_expression(Expression.new(:and_then, [assign_line.parameters[1], new_block]))
  else
    f.append_expression(Expression.new(:within, [assign_line.parameters[1], new_block]))
  end

  self.do_blockify(new_block)
end

example = <<-macaron
do_block {
  a <= do_first(1)
  b = a + 4
  c <= do_second(b)
  d = c + 4
  e <= do_third(d)
  e + 4
}

do_first(1).and_then do |a|
  b = a + 4
  do_second(b).and_then do |c|
    d = c + 4
    do_third(d).within do |e|
      e + 4
    end
  end
end
macaron



