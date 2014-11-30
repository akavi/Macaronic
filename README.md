# Macaronic

Have you ever been writing ruby and though, you know what? Ruby syntax is really flexible and all, but that's not enough. What I *really* need is the ability to reach down into the guts of MRI and twist the AST to my will. At runtime.

Of course you have. 

Well, finally there's an answer. Macaronic's aim is to provide you with runtime access to a mutable AST. Because flexible syntax can always be flexibiler

(NB: Only *very* basic functionality implemented. Lots of things (`if` statements, for example) aren't working yet, so, uh, bear with me)

## Example

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

## FAQ

1. Is this a good idea?

lolno
