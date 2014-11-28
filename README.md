# Macaronic

Have you ever been writing ruby and though, you know what? Ruby syntax is really flexible and all, but that's not enough. What I *really* need is the ability to reach down into the guts of MRI and twist the AST to my will. At runtime.

Of course you have. 

Well, finally there's an answer. Or, uh, will be. Real Soon. A bit of a work in progress at the moment. The aim, at least, is to provide you with runtime access to a mutable AST. Because flexible syntax can always be flexibiler

### Example: Haskell "Do Notation" (Not yet working)

Write this:

```
  do_block {
    a <= do_first(1)
    b = a + 4
    c <= do_second(b)
    d = c + 4
    e <= do_third(d)
    e + 4
  }
```

and have it converted, at runtime, to:

```
do_first(1).and_then do |a|
  b = a + 4
  do_second(b).and_then do |c|
    d = c + 4
    do_third(d).within do |e|
      e + 4
    end
  end
end
```
(`and_then` is like Scala's `flatmap` or Haskell's `bind`. `within` is like Scala's `map` or Haskell's `>=>`)
