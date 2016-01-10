require 'iseq'
require 'pp'

class Macaronic
  class Literal
    attr_accessor :value
    def initialize(value)
      @value = value
    end

    def to_iseq(frame)
      [[:putobject, @value], [:pop]]
    end

    def inspect
      @value
    end

    def traverse_and_replace(&block)
      @value = yield @value
    end
  end

  class ArrayLiteral < Literal
    def to_iseq(frame)
      codes = @value.flat_map { |val| val.to_iseq(frame)[0...-1] }
      codes.push [:newarray, @value.size]
      codes.push [:pop]
      codes
    end

    def traverse_and_replace(&block)
      self.value.each.with_index do |v, i| 
        res = yield v
        if res == v && v.respond_to?(:traverse_and_replace)
          v.traverse_and_replace(&block)
        else
          self.value[i] = res
        end
      end
    end
  end

  class Self
    def to_iseq(frame)
      [[:putself], [:pop]]
    end

    def inspect
      :self
    end
  end

  class Expression
    attr_accessor :method
    attr_accessor :arguments
    attr_accessor :is_private

    def initialize(method, arguments, is_private = false)
      @method = method
      @arguments = arguments
      @is_private = is_private
    end

    def receiver
      @arguments.first
    end

    def inspect
      args = @arguments[1..-1].map(&:inspect).join(", ")
      "#{@arguments.first.inspect}.#{@method.to_s}(#{})"
    end

    def to_iseq(frame)
      block_args, simple_args = self.arguments.partition { |a| a.is_a? Macaronic::Frame }
      argument_bytecode = simple_args.flat_map do  |a| 
        # get rid of the default pop
        a.to_iseq(frame)[0...-1]
      end

      options = {
        mid: @method,
        orig_argc: simple_args.length - 1,
        flag: 0
      }
      options[:blockptr] = block_args.first.to_iseq if block_args.any?
      options[:flag] |= 8 if is_private
      call_bytecode  = [:send, options]

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
      "#{@local.inspect}=#{@value.inspect}"
    end

    def to_iseq(frame)
      value_bytecodes = [value]
      value_bytecodes = value.to_iseq(frame) if value.respond_to? :to_iseq
      set_bytecode = [:setlocal, @local.scope.depth, @local.index]
      value_bytecodes.push set_bytecode
      value_bytecodes.push [:pop]
    end
  end

  class Label
    attr_accessor :name
    def initialize(name)
      @name = name
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
      search_depth = frame.depth - @scope.depth
      if search_depth == 0
        :getlocal_OP__WC__0
        [[:getlocal_OP__WC__0, @index], [:pop]]
      elsif search_depth == 1
        [[:getlocal_OP__WC__1, @index], [:pop]]
      else
        [[:getlocal, frame.depth - @scope.depth, @index], [:pop]]
      end
    end
  end

  class If
    attr_accessor :test, :if_expressions, :else_expressions

    def initialize(test, if_expressions, else_expressions)
      @test = test
      @if_expressions = if_expressions
      @else_expressions = else_expressions
    end

    def inspect
      "if #{@test.inspect} then #{@if_expressions.inspect} else #{@else_expressions}"
    end
  end

  module FrameFromIseq
    class IfHole
      attr_accessor :test, :else_label, :if_label, :if_expressions, :else_expressions
      def initialize(test, if_label, if_expressions, else_label, else_expressions)
        @test = test
        @if_label = if_label
        @if_expressions = if_expressions
        @else_label = else_label
        @else_expressions = else_expressions
      end
    end

    class Jump
      attr_accessor :label
      def initialize(label)
        @label = label
      end

      def inspect
        "jump to #{@label}"
      end
    end

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

    # TODO support early return/break
    # TODO support whiles
    def expressions_from_iseq(bytecodes, locals)
      bytecodes.reduce([]) do |stack, inst|
        puts "STACK: #{stack}"
        puts "INST: #{inst}"
        # annoyingly, labels have have their own format
        # UGGGGLY, TODO: refactor
        if inst.is_a?(Symbol) && inst.to_s =~ /^label/
          if ih = self.half_pop_if(inst, stack)
            stack << ih
          elsif iff = self.pop_if(inst, stack)
            stack << iff 
          end

          next stack
        elsif inst.is_a?(Fixnum)
          # TODO: What's with the plain numbers?
          next stack
        end

        case inst[0]
        when :throw
          # TODO
        when :trace
          # do nothing
          # TODO?
         
        when :branchunless
          test = stack.pop
          if_hole = IfHole.new(test, inst[1], nil, nil, nil)
          stack << if_hole
        when :jump
          stack << Jump.new(inst[1])

        when :putobject_OP_INT2FIX_O_0_C_ 
          stack << Literal.new(0)
        when :putobject_OP_INT2FIX_O_1_C_ 
          stack << Literal.new(1)
        when :putobject
          stack << Literal.new(inst[1])
        when :putstring
          stack << Literal.new(inst[1])
        when :putself
          stack << Self.new
        when :newarray
          stack << self.pop_array(inst[1], stack)
        when :duparrray
          stack << ArrayLiteral.new(inst[1].map{ |v| Literal.new(v)})

        when :getlocal
          stack << self.get_local(inst[2], inst[1])
        when :getlocal_OP__WC__1
          stack << self.get_local(1, inst[1])
        when :getlocal_OP__WC__0
          stack << self.get_local(0, inst[1])

        when :setlocal
          stack << self.pop_assignment(inst[2], inst[1], stack)
        when :setlocal_OP__WC__1
          stack << self.pop_assignment(1, inst[1], stack)
        when :setlocal_OP__WC__0
          stack << self.pop_assignment(0, inst[1], stack)

        when :send
          stack << self.pop_expression(inst[1], stack)
        when :opt_send_simple
          stack << self.pop_expression(inst[1], stack)
        when :opt_lt
          stack << self.pop_expression(inst[1], stack)
        when :opt_le
          stack << self.pop_expression(inst[1], stack)
        when :opt_plus
          stack << self.pop_expression(inst[1], stack)
        # TODO: The other opts and sends
        else
          puts "UNKNOWN"
        end

        stack
      end
    end

    def half_pop_if(label, stack)
      if ih = stack.find{ |exp| exp.is_a?(IfHole) && exp.if_label == label }
        ih.else_label = stack.pop.label

        if_exprs = []
        while (expr = stack.pop) != ih
          if_exprs.unshift expr 
        end
        ih.if_expressions =  if_exprs

        ih
      end
    end

    def pop_if(label, stack)
      if ih = stack.find{ |exp| exp.is_a?(IfHole) && exp.else_label == label }
        if child_if = self.pop_if(label, ih.if_expressions)
          ih.if_expressions << child_if
        end

        else_exprs = []
        while (expr = stack.pop) != ih
          else_exprs.unshift expr 
        end

        If.new(ih.test, ih.if_expressions, else_exprs)
      end
    end

    def pop_expression(inst, stack)
      args = stack.pop(inst[:orig_argc] + 1)
      args.push Frame.new(self, inst[:blockptr]) if inst[:blockptr]
      is_private = inst[:flag] & 8
      Expression.new inst[:mid], args, is_private
    end

    def pop_assignment(depth, index, stack)
      local = get_local(depth, index)
      value = stack.pop
      Assignment.new(local, value)
    end
    
    def pop_array(count, stack)
      values = stack.pop(count)
      ArrayLiteral.new(values)
    end

    def get_local(depth, index)
      scope = self
      depth.times { scope = scope.parent_scope }
      scope.locals.find { |l| l.index == index }
    end
  end

  module FrameToIseq
    def prep_to_iseq
      local_count = self.locals.size
      self.locals.map.with_index{ |l, i| l.index = local_count + 1 - i }
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
      splat_index = self.locals.index{ |l| l.type == :splat_argument } || -1
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

    # TODO: Figure out what this does?
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
      local.scope = self
      self.traverse_and_replace do |n|
        if n.is_a?(Macaronic::Expression) && n.receiver.is_a?(Macaronic::Self) && n.method == local.label
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

  # TODO: Remove this once you figure out how
  # rb_iseq_load allows passing in of enclosing scope
  def self.wrap_with_top(iseq)
    wrapper = ["YARVInstructionSequence/SimpleDataFormat", 2, 1, 1, {:arg_size=>0, :local_size=>1, :stack_max=>1}, "<compiled>", "<compiled>", nil, 1, :top, [], 0, [], :tbd]
    wrapper[13] = [
      [:putself],
      [:send, {mid: :proc, blockptr: iseq, flag: 8, orig_argc: 0}],
      [:leave]
    ]
    wrapper
  end

  def self.load(frame)
    frame_iseq = frame.to_iseq
    frame_iseq = self.wrap_with_top(frame_iseq) unless frame.type == :top
    ISeq.load(frame_iseq)
  end

  def self.on(block)
    frame = self.splode(block)
    frame = yield frame
    self.load(frame).eval
  end
end
