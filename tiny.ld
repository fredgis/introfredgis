/* Minimal PE layout: code and constants in .text, imports in .idata, .bss.
   Everything else the default script emits (ctor/dtor lists, pseudo relocs,
   .edata, .tls, .didat) is junk for this program and only costs a whole
   file-alignment block each, so it is discarded. */
SECTIONS
{
  . = SIZEOF_HEADERS;
  . = ALIGN(__section_alignment__);
  .text __image_base__ + ( __section_alignment__ < 0x1000 ? . : __section_alignment__ ) :
  {
    *(.text)
    *(SORT(.text$*))
    *(.text.*)
    *(.rdata)
    *(SORT(.rdata$*))
    *(.data)
    *(SORT(.data$*))
  }
  .bss BLOCK(__section_alignment__) :
  {
    *(.bss)
    *(COMMON)
  }
  .idata BLOCK(__section_alignment__) :
  {
    KEEP (SORT(*)(.idata$2))
    KEEP (SORT(*)(.idata$3))
    LONG (0); LONG (0); LONG (0); LONG (0); LONG (0);
    . = ALIGN(8);
    KEEP (SORT(*)(.idata$4))
    __IAT_start__ = .;
    SORT(*)(.idata$5)
    __IAT_end__ = .;
    KEEP (SORT(*)(.idata$6))
    KEEP (SORT(*)(.idata$7))
  }
  /DISCARD/ :
  {
    *(.ctors) *(.dtors) *(.ctors.*) *(.dtors.*)
    *(.CRT$*) *(.tls) *(.tls$*) *(.edata) *(.didat$*)
    *(.rdata_runtime_pseudo_reloc) *(.jcr) *(.eh_frame)
    *(.debug$S) *(.debug$T) *(.debug$F) *(.drectve)
    *(.note.GNU-stack) *(.gnu.lto_*) *(.gnu_object_only)
  }
}
