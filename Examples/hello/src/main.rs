use std::collections::HashMap;
use std::fmt;

/// A shape with an area.
trait Shape {
    fn area(&self) -> f64;
}

#[derive(Debug, Clone, Copy)]
struct Circle {
    radius: f64,
}

impl Shape for Circle {
    fn area(&self) -> f64 {
        std::f64::consts::PI * self.radius * self.radius
    }
}

impl fmt::Display for Circle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Circle(r = {})", self.radius)
    }
}

/// Greets someone by name.
fn greet(name: &str) -> String {
    format!("Hello, {name}!")
}

fn longest<'a>(a: &'a str, b: &'a str) -> &'a str {
    if a.len() >= b.len() { a } else { b }
}

fn main() {
    let names = ["Ferris", "world"];
    for name in names {
        println!("{}", greet(name));
    }

    let mut counts: HashMap<char, usize> = HashMap::new();
    for c in longest("ownership", "borrow").chars() {
        *counts.entry(c).or_insert(0) += 1;
    }
    let circle = Circle { radius: 2.0 };
    println!("{circle} has area {:.2}; {} distinct letters", circle.area(), counts.len());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greets_by_name() {
        assert_eq!(greet("Ferris"), "Hello, Ferris!");
    }

    #[test]
    fn picks_the_longer_string() {
        assert_eq!(longest("ab", "abc"), "abc");
    }
}
