class MyClass {
  int fieldName;

  MyClass(this.fieldName);

  @pragma('dart2js:noInline')
  int second() => fieldName;

  @pragma('dart2js:tryInline')
  int first() => /*1:first(inlined)*/ second();
  // TODO(36841): The above entry should not be on the stack for a null
  // receiver.
}

@pragma('dart2js:noInline')
confuse(x) => x;

@pragma('dart2js:noInline')
sink(x) {}

main() {
  confuse(new MyClass(3));
  var m = confuse(null);
  sink(/*0:main*/ m.first());
  sink(m); // TODO(39998): Remove second use of 'm'.
}
