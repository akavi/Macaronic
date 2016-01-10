# Macaronic

Have you ever been writing ruby and thought, you know what? Ruby syntax is really flexible and all, but that's not enough. What I *really* need is the ability to reach down into the guts of MRI and twist the AST to my will. At runtime.

Of course you have. 

Well, finally there's an answer. Macaronic's aim is to provide you with runtime access to a mutable AST. Because flexible syntax can always be flexibiler

(NB: Only basic functionality implemented. Lots of things (exceptions, for example) aren't working yet, so, uh, bear with me)

## An example

Take a little proc that, say, prints a string
```
> original = proc{ puts "hello world!" }
 => #<Proc:0x007fcca48a0930@(irb):185> 
> original.call
hello world!
 => nil 
```

Have Macaronic parse it
```
> original_ast = Macaronic.splode(original)
 => {:locals=>[], :expressions=>[[:self, :puts, ["\"hello world!\""]]]} 
> original_ast.expressions.first.arguments[1]
 => "hello world!" 
```

Modify its AST to your heart's content and reload it
```
> original_ast.expressions.first.arguments[1] = "hello mars!"
 => "hello mars!" 
> modded = Macaronic.load(original_ast)
 => #<Proc:0x007fcca5885df0@<compiled>:0> 
```

Enjoy your shiny new, run-time improved block of code
```
> modded.call
hello mars!
 => nil 
```

## But let's get crazier

(Take a look at `do_block.rb` to see the implementation of this. Use of `and_then` and `within` comes from [here](http://codon.com/refactoring-ruby-with-monads))

Write this:
```
do_block do 
 x <= [1, 2, 3]
 y <= ["a", "b", "c"]
 z <= [:foo, :bar, :baz]
 [x, y, z]
end
```

And have it converted before execution into this:
```
[1, 2, 3].and_then do |x|
  ["a", "b", "c"].and_then do |y|
    [:foo, :bar, :baz].within do |z|
      [x, y, z]
    end
  end
end
```

Yay, Haskell do-notation, in Ruby!


## FAQ

1. Is this a good idea?

lolno
