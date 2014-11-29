class Macaronic
  class Self
    def to_iseq(frame)
      [[:putself]]
    end
  end

  class Expression
    attr_accessor :method
    attr_accessor :arguments

    def initialize(method, arguments)
      @method = method
      @arguments = arguments
    end

    def inspect
      [@arguments.first.inspect, @method, @arguments[1..-1].map(&:inspect)]
    end

    def to_iseq(frame)
      block_args, simple_args = self.arguments.partition { |a| a.is_a? Frame }
      argument_bytecode = simple_args.flat_map do  |a| 
        if a.respond_to? :to_iseq
          a.to_iseq(frame)
        else
          [[:putobject, a]]
        end
      end
      argument_bytecode.pop

      options = {
        mid: @method,
        orig_argc: simple_args.length - 1,
      }
      options[:inst_blockptr] = block_args.first.to_iseq if block_args.any?
      call_bytecode  = [:send, @method, options]

      argument_bytecode.push call_bytecode
      argument_bytecode.push [:pop]
    end

    def traverse_and_replace(&block)
      self.arguments.each.with_index do |a, i| 
        res = yield a
        if res == a && a.respond_to?(:traverse_and_replace)
          res.traverse_and_replace(&block)
        else
          self.arguments[i] = res
        end
      end
    end
  end

  class Assignment
    attr_accessor :local
    attr_accessor :value

    def initialize(local, value)
      @local = local
      @value = value
    end

    def inspect
      [@local.inspect, "=", @value.inspect]
    end

    def to_iseq(frame)
      value_bytecodes = [value]
      value_bytecodes = value.to_iseq(frame) if value.respond_to? :to_iseq
      set_bytecode = [:setlocal, @local.scope.depth, @local.index]
      value_bytecodes.push set_bytecode
      value_bytecodes.push [:pop]
    end
  end

  class Local
    attr_accessor :scope
    attr_accessor :type
    attr_accessor :label
    attr_accessor :index


    def initialize(scope, type, label, index = nil)
      @scope = scope
      @type = type
      @label = label
      @index = index
    end

    def inspect
      @label
    end

    def to_iseq(frame)
      [[:getlocal, frame.depth - @scope.depth, @index]]
    end
  end

  module FrameFromIseq
    def initialize_from_iseq(parent_scope, iseq)
      @parent_scope = parent_scope
      @type = iseq[9]

      # these must be done in order
      @depth = @parent_scope ? @parent_scope.depth + 1 : 0
      @locals = locals_from_iseq(iseq[10], iseq[11])
      @expressions = expressions_from_iseq(iseq[13], iseq[10])
    end
    #
    # TODO support block_arguments
    def locals_from_iseq(labels, info)
      if info.is_a? Integer
        params = labels.map.with_index do |l, i|
          weird_index = labels.length + 1 - i

          if i < info
            Local.new(self, :simple_argument, labels[i], weird_index)
          else
            Local.new(self, :simple_local, labels[i], weird_index)
          end
        end
      else
        simple_bound = info[0]
        optional_bound = simple_bound + [info[1].length - 1, 0].max
        splat_bound = [optional_bound, info[3]].max
        post_simple_bound = splat_bound + info[2]
        puts "simple_bound #{simple_bound}"
        puts "optional_bound #{optional_bound}"
        puts "splat_bound #{splat_bound}"
        params = labels.map.with_index do |l, i|
          weird_index = labels.length + 1 - i

          if i < simple_bound
            Local.new(self, :simple_argument, labels[i], weird_index)
          elsif i < optional_bound
            Local.new(self, :optional_argument, labels[i], weird_index)
          elsif i < splat_bound
            Local.new(self, :splat_argument, labels[i], weird_index)
          elsif i < post_simple_bound
            Local.new(self, :post_argument, labels[i], weird_index)
          else
            Local.new(self, :simple_local, labels[i], weird_index)
          end
        end
      end
    end

    def expressions_from_iseq(bytecodes, locals)
      expressions = []
      stack = []
      bytecodes.each do |inst|
        next unless inst.is_a? Array
        next if inst[0] == :trace
        # TODO: support ifs/whiles
        next if inst[0] == :jump
        #stack << stack.last if inst[0] == :dup

        stack << 0 if inst[0] == :putobject_OP_INT2FIX_O_0_C_ 
        stack << 1 if inst[0] == :putobject_OP_INT2FIX_O_1_C_ 
        stack << [] if inst[0] == :newarray
        stack << inst[1] if inst[0] == :putobject
        stack << Self.new if inst[0] == :putself

        stack << self.get_local(inst[2], inst[1]) if inst[0] == :getlocal
        stack << self.get_local(1, inst[1]) if inst[0] == :getlocal_OP__WC__1
        stack << self.get_local(0, inst[1]) if inst[0] == :getlocal_OP__WC__0

        stack << self.pop_assignment(inst[2], inst[1], stack) if inst[0] == :setlocal
        stack << self.pop_assignment(1, inst[1], stack) if inst[0] == :setlocal_OP__WC__1
        stack << self.pop_assignment(0, inst[1], stack) if inst[0] == :setlocal_OP__WC__0

        stack << self.pop_expression(inst[1], stack) if inst[0] == :send
        stack << self.pop_expression(inst[1], stack) if inst[0] == :opt_send_simple
        stack << self.pop_expression(inst[1], stack) if inst[0] == :opt_le
        stack << self.pop_expression(inst[1], stack) if inst[0] == :opt_plus
      end

      stack
    end

    def pop_expression(inst, stack)
      args = stack.pop(inst[:orig_argc] + 1)
      args.push Frame.new(self, inst[:blockptr]) if inst[:blockptr]
      Expression.new inst[:mid], args
    end

    def pop_assignment(depth, index, stack)
      local = get_local(depth, index)
      value = stack.pop
      Assignment.new(local, value)
    end

    def get_local(depth, index)
      scope = self
      depth.times { scope = scope.parent_scope }
      scope.locals.find { |l| l.index == index }
    end
  end

  module FrameToIseq
    def prep_to_iseq

    end

    def to_iseq(parent_frame = nil)
      self.prep_to_iseq

      [
        "YARVInstructionSequence/SimpleDataFormat",
        2, 1, 1,
        {
          arg_size: self.to_iseq_arg_size,
          local_size: self.to_iseq_local_size,
          stack_max: self.to_iseq_stack_max,
        },
        "<compiled>", "<compiled>", nil, 1,
        @type,
        self.to_iseq_local_labels,
        self.to_iseq_arg_format,
        [], # TODO: catch table
        self.to_iseq_bytecode
      ]
    end

    def to_iseq_local_labels
      self.locals.map(&:label)
    end

    def to_iseq_arg_format
      simple_count = self.locals.select{ |l| l.type == :simple_argument }.size
      post_count = self.locals.select{ |l| l.type == :post_argument }.size
      splat_index = self.locals.index{ |l| l.type == :splat_argument } || 0
      # TODO: Block args
      # TODO: Optional args
      [simple_count, [], post_count, splat_index + 1, splat_index, -1, 0]
    end
    
    def to_iseq_arg_size
      self.locals.select { |l| l.type.match(/argument/) }.size
    end

    def to_iseq_local_size
      self.locals.size + 1
    end

    def to_iseq_stack_max
      10
    end

    def to_iseq_bytecode
      bytecode = self.expressions.flat_map { |e| e.to_iseq(self) }
      bytecode.pop
      bytecode.push [:leave]
    end
  end

  class Frame
    include FrameFromIseq
    include FrameToIseq

    attr_accessor :type
    attr_accessor :parent_scope
    attr_accessor :locals
    attr_accessor :expressions
    attr_accessor :depth

    def initialize(parent_scope, type, locals = nil, expressions = nil)
      return initialize_from_iseq(parent_scope, type) unless type.is_a? Symbol

      @parent_scope = parent_scope
      @type = type
      @locals = locals
      @locals.each { |l| l.scope = self }
      @expressions = expressions
      @depth = @parent_scope ? @parent_scope.depth + 1 : 0
    end

    def inspect
      {
        locals: @locals.map(&:inspect),
        expressions: @expressions.map(&:inspect)
      }
    end

    def traverse_and_replace(&block)
      self.expressions.each.with_index do |e, i| 
        res = yield e
        if res == e
          res.traverse_and_replace(&block)
        else
          self.expressions[i] = res
        end
      end
    end

    def shadow(local)
      self.traverse_and_replace do |n|
        if n.is_a?(Macaronic::Expression) && n.receiver == :self && n.method == local.label
          local
        else
          n
        end
      end
    end
  end

  def self.splode(data)
    data = ISeq.of(data) if data.is_a? Proc
    data = data.to_a if data.is_a? ISeq

    Frame.new(nil, data)
  end

  def self.load(frame)
    ISeq.load(frame.to_iseq)
  end

  def self.on(block)
    frame = self.splode(block)
    frame = yield frame
    #self.load(frame)
  end
end

def do_block(&block)
  Macaronic.on(block){ |f| do_blockify(f) }
end

def do_blockify(f)
  back_assign_idxs = f.expressions.each_index.select { |i| f.expressions[i].method == :<= }
  first_idx = back_assign_idxs[0]
  return f unless first_idx
  assign_line = f.expressions[first_idx]

  new_block_expressions = f.expressions[(first_idx + 1)..-1]
  f.expressions = f.expressions[0...first_idx]
  new_block_arg = Macaronic::Local.new(nil, :simple_argument, assign_line.receiver.method)
  new_block = Macaronic::Frame.new(f, :block, [new_block_arg], new_block_expressions)
  new_block.shadow(new_block_arg)

  if back_assign_idxs.length > 1
    f.expressions.push(Macaronic::Expression.new(assign_line.arguments[0], :and_then, [new_block]))
  else
    f.expressions.push(Macaronic::Expression.new(assign_line.arguments[0], :within, [new_block]))
  end

  do_blockify(new_block)
  f
end
