package main

import "fmt"

// Hello prints a greeting
func Hello(name string) string {
	return fmt.Sprintf("Hello, %s!", name)
}

func main() {
	msg := Hello("world")
	fmt.Println(msg)
}
