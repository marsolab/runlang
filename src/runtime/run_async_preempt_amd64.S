.text
.globl run_async_preempt
#if defined(__APPLE__)
.globl _run_async_preempt
_run_async_preempt:
#endif
run_async_preempt:
    /* Save all caller-saved registers (the signal interrupted arbitrary code) */
    pushq   %rax
    pushq   %rcx
    pushq   %rdx
    pushq   %rsi
    pushq   %rdi
    pushq   %r8
    pushq   %r9
    pushq   %r10
    pushq   %r11
    /* Call run_yield() */
#if defined(__APPLE__)
    callq   _run_yield
#else
    callq   run_yield
#endif
    /* Restore caller-saved registers */
    popq    %r11
    popq    %r10
    popq    %r9
    popq    %r8
    popq    %rdi
    popq    %rsi
    popq    %rdx
    popq    %rcx
    popq    %rax
    ret

#if defined(__linux__)
.section .note.GNU-stack,"",@progbits
#endif
