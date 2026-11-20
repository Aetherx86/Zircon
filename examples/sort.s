# Bubble sort of twelve signed words, then sum them with a multiply-accumulate.
# Exercises loads, stores, branches, RV32M and the cycle counter.

        la   s0, data
        li   s1, 12              # element count
outer:  addi s1, s1, -1
        blez s1, sum
        mv   t0, s0
        mv   t1, s1
inner:  lw   t2, 0(t0)
        lw   t3, 4(t0)           # load-use stall on the next line
        ble  t2, t3, noswap
        sw   t3, 0(t0)
        sw   t2, 4(t0)
noswap: addi t0, t0, 4
        addi t1, t1, -1
        bnez t1, inner
        j    outer

sum:    mv   t0, s0
        li   t1, 12
        li   a0, 0
        li   t4, 3
acc:    lw   t2, 0(t0)
        mul  t2, t2, t4          # a0 += 3 * data[i]
        add  a0, a0, t2
        addi t0, t0, 4
        addi t1, t1, -1
        bnez t1, acc
        rdcycle a1               # cycles spent so far
        ecall

        .align 2
data:   .word 9, -3, 7, 0, 12, 5, -8, 1, 4, 4, 100, -100
