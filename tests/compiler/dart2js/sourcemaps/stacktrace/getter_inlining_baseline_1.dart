class MyClass {
  int fieldName;

  MyClass(this.fieldName);

  // This is a baseline test for no inlining of getter.
  @pragma('dart2js:noInline')
  int get getterName => fieldName;
}

@pragma('dart2js:noInline')
confuse(x) => x;

@pragma('dart2js:noInline')
sink(x) {}

main() {
  confuse(new MyClass(3));
  var m = /*0:main*/ confuse(null);
  sink(m.getterName);
  //     ^ Should be here.
  //
  // TODO(39998): Fix this. The compiled code looks like
  //
  //     Y.sink(Y.confuse(null).get$getterName());
  //
  // The previous call is the receiver for the faulting call. It appears these
  // are being conflated.
}
