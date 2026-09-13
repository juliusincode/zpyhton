# zpython demo

print("=== arithmetic ===")
print(1 + 2 * 3)
print(2 ** 10)
print(17 // 5)
print(17 % 5)

print("=== strings ===")
print("hello" + " " + "zpython")

print("=== while ===")
n = 0
while n < 3:
    print(n)
    n = n + 1

print("=== for + range ===")
for i in range(0, 5):
    print(i)

print("=== functions ===")
def add(a, b):
    return a + b

print(add(10, 32))

def fact(n):
    if n <= 1:
        return 1
    return n * fact(n - 1)

print(fact(6))

print("=== if/else ===")
x = 42
if x > 100:
    print("huge")
elif x > 40:
    print("medium")
else:
    print("small")

print("=== lists ===")
xs = range(3)
print(len(xs))
print(xs)

print("done")
