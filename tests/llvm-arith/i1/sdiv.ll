define i1 @main(i1 %argc, i8** %arcv) {
  %1 = sdiv i1 1, 1
  ret i1 %1
}

; ASSERT EQ: i1 1 = call i1 @main(i64 0, i8** null)

