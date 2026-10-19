/* bare-metal Cortex-M7 image for QEMU mps2-an500 (instruction counting only) */
ENTRY(Reset_Handler)
MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 4M  PSRAM (rwx) : ORIGIN = 0x60000000, LENGTH = 16M }
SECTIONS {
  .text : { KEEP(*(.vectors)) *(.text*) *(.rodata*) KEEP(*(.init)) KEEP(*(.fini)) . = ALIGN(4); } > RAM
  .ARM.exidx : { *(.ARM.exidx*) } > RAM
  .init_array : { PROVIDE(__init_array_start = .); KEEP(*(.init_array*)) PROVIDE(__init_array_end = .); } > RAM
  .fini_array : { PROVIDE(__fini_array_start = .); KEEP(*(.fini_array*)) PROVIDE(__fini_array_end = .); } > RAM
  .preinit_array : { PROVIDE(__preinit_array_start = .); KEEP(*(.preinit_array*)) PROVIDE(__preinit_array_end = .); } > RAM
  .data : { *(.data*) } > RAM
  .bss : { __bss_start__ = .; *(.bss*) *(COMMON) __bss_end__ = .; } > RAM
  end = .; PROVIDE(_end = .); PROVIDE(__end__ = .);
  __stack = 0x00400000; PROVIDE(__StackTop = __stack);
}
