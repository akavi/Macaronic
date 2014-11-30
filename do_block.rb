require './macaronic.rb'

class Array
  def and_then(&block)
    self.flat_map do |a|
      block.call(a)
    end
  end

  def within(&block)
    and_then do |value|
      [block.call(value)]
    end
  end
end

def do_block(&block)
  Macaronic.on(block){ |f| do_blockify(f) }.call
end

def do_blockify(frame)
  # find lines to rewrite
  back_assign_idxs = frame.expressions.each_index.select { |i| 
    frame.expressions[i].is_a?(Macaronic::Expression) && frame.expressions[i].method == :<=
  }
  first_idx = back_assign_idxs[0]
  return frame unless first_idx

  # rewrite the line into a block
  assign_line = frame.expressions[first_idx]
  new_block_expressions = frame.expressions[(first_idx + 1)..-1]
  local_label = assign_line.receiver.method
  new_block_arg = Macaronic::Local.new(nil, :simple_argument, local_label)
  new_block = Macaronic::Frame.new(frame, :block, [new_block_arg], new_block_expressions)
  new_block.shadow(new_block_arg)
  # and then recurse on it
  do_blockify(new_block)

  # attach line back to surrounding scope
  new_args = [assign_line.arguments[1], new_block]
  if back_assign_idxs.length > 1
    new_expression = Macaronic::Expression.new(:and_then, new_args)
  else
    new_expression = Macaronic::Expression.new(:within, new_args)
  end
  frame.expressions = frame.expressions[0...first_idx]
  frame.expressions.push new_expression

  frame
end
