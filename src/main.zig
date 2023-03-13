const std = @import("std");
const assert = std.debug.assert;

const ADDRESS_BIT_SIZE = 64;

const PAGE_DIRECTORY_L1_BITS = 10;
const PAGE_DIRECTORY_L2_BITS = 16;
const PAGE_DIRECTORY_L3_BITS = 16;
const PAGE_DIRECTORY_L4_BITS = 10;
const PAGE_SIZE_BITS = ADDRESS_BIT_SIZE - PAGE_DIRECTORY_L1_BITS - PAGE_DIRECTORY_L2_BITS - PAGE_DIRECTORY_L3_BITS - PAGE_DIRECTORY_L4_BITS;

const PAGE_DIRECTORY_L1_SIZE = 1 << PAGE_DIRECTORY_L1_BITS;
const PAGE_DIRECTORY_L2_SIZE = 1 << PAGE_DIRECTORY_L2_BITS;
const PAGE_DIRECTORY_L3_SIZE = 1 << PAGE_DIRECTORY_L3_BITS;
const PAGE_DIRECTORY_L4_SIZE = 1 << PAGE_DIRECTORY_L4_BITS;
const PAGE_SIZE = (1 << PAGE_SIZE_BITS);

const PAGE_DIRECTORY_L1_MASK:   u64 = (PAGE_DIRECTORY_L1_SIZE - 1);
const PAGE_DIRECTORY_L2_MASK:   u64 = (PAGE_DIRECTORY_L2_SIZE - 1);
const PAGE_DIRECTORY_L3_MASK:   u64 = (PAGE_DIRECTORY_L3_SIZE - 1);
const OFFSET_MASK: u64 = (PAGE_SIZE - 1);

const VALID_PAGE_BIT = (1 << 0);

const Page_Directory_L1 = struct
{
  entries: [PAGE_DIRECTORY_L1_SIZE]u64,
};

const Page_Directory_L2 = struct
{
  entries: [PAGE_DIRECTORY_L2_SIZE]?*Page_Directory_L1,
};

const Page_Directory_L3 = struct
{
  entries: [PAGE_DIRECTORY_L3_SIZE]?*Page_Directory_L2,
};

const Page_Directory_L4 = struct
{
  // NOTE(fakhri):  next_virt_addr is partitioned like this:
  //   ____________________________________________________
  //  | unused | l4 index | l3 index | l2 index | l1 index |
  //   ----------------------------------------------------
  next_virt_addr: u64,
  
  entries: [PAGE_DIRECTORY_L4_SIZE]?*Page_Directory_L3,
};

const Virtual_Memory_Error = error
{
  PageFault,
  OutOfMemory,
  InternalError,
};

// NOTE(fakhri):  virtual address is partitioned like this
//   _________________________________________
//  | l3 index | l2 index | l1 index | offset |
//   -----------------------------------------

pub fn translate_virt_addr(page_directory: *Page_Directory_L4, virt_addr: u64) Virtual_Memory_Error!u64
{
  const l4_index = (virt_addr >> (PAGE_SIZE_BITS + PAGE_DIRECTORY_L1_BITS + PAGE_DIRECTORY_L2_BITS + PAGE_DIRECTORY_L3_BITS));
  const l3_index = (virt_addr >> (PAGE_SIZE_BITS + PAGE_DIRECTORY_L1_BITS + PAGE_DIRECTORY_L2_BITS)) & PAGE_DIRECTORY_L3_MASK;
  const l2_index = (virt_addr >> (PAGE_SIZE_BITS + PAGE_DIRECTORY_L1_BITS)) & PAGE_DIRECTORY_L2_MASK;
  const l1_index = (virt_addr >> PAGE_SIZE_BITS) & PAGE_DIRECTORY_L1_MASK;
  const offset = virt_addr & OFFSET_MASK;
  
  if (page_directory.entries[l4_index]) |l3_entry|
  {
    if (l3_entry.entries[l3_index]) |l2_entry|
    {
      if (l2_entry.entries[l2_index]) |l1_entry|
      {
        const physical_page = l1_entry.entries[l1_index];
        if ((physical_page & VALID_PAGE_BIT) == 0)
        {
          return Virtual_Memory_Error.PageFault;
        }
        
        const phys_address: u64 = ((physical_page & ~OFFSET_MASK) | offset);
        return phys_address;
      }
    }
  }
  
  return Virtual_Memory_Error.PageFault;
}

const MEMORY_SIZE: u64 = (1 << 32);
var USED_MEMORY: u64 = 0;

pub fn allocate_physical_page(page_directory: *Page_Directory_L4, allocator: std.mem.Allocator) Virtual_Memory_Error!u64
{
  if (USED_MEMORY + PAGE_SIZE > MEMORY_SIZE)
  {
    return Virtual_Memory_Error.OutOfMemory;
  }
  
  var phys_address :u64= USED_MEMORY;
  phys_address |= VALID_PAGE_BIT;
  
  USED_MEMORY += PAGE_SIZE;
  
  const max_virt_addr :u64= (1 << (PAGE_DIRECTORY_L1_BITS + PAGE_DIRECTORY_L2_BITS + PAGE_DIRECTORY_L3_BITS + PAGE_DIRECTORY_L4_BITS));
  if (page_directory.next_virt_addr >= max_virt_addr)
  {
    // NOTE(fakhri): physical space is bigger than virtual space
    return Virtual_Memory_Error.InternalError;
  }
  
  const l4_index = (page_directory.next_virt_addr >> (PAGE_DIRECTORY_L1_BITS + PAGE_DIRECTORY_L2_BITS + PAGE_DIRECTORY_L3_BITS));
  const l3_index = (page_directory.next_virt_addr >> (PAGE_DIRECTORY_L1_BITS + PAGE_DIRECTORY_L2_BITS)) & PAGE_DIRECTORY_L3_MASK;
  const l2_index = (page_directory.next_virt_addr >> PAGE_DIRECTORY_L1_BITS) & PAGE_DIRECTORY_L2_MASK;
  const l1_index = page_directory.next_virt_addr & PAGE_DIRECTORY_L1_MASK;
  
  page_directory.next_virt_addr += 1;
  
  var page_dir_l3: *Page_Directory_L3 = undefined;
  var page_dir_l2: *Page_Directory_L2 = undefined;
  var page_dir_l1: *Page_Directory_L1 = undefined;
  
  // NOTE(fakhri): get level 3 page directory
  {
    if (page_directory.entries[l4_index] == null)
    {
      page_dir_l3 = try allocator.create(Page_Directory_L3);
      page_directory.entries[l4_index] = page_dir_l3;
      page_dir_l3.entries = [_]?*Page_Directory_L2{null} ** PAGE_DIRECTORY_L3_SIZE;
    }
    else
    {
      page_dir_l3 = page_directory.entries[l4_index].?;
    }
  }
  
  // NOTE(fakhri): get level 2 page directory
  {
    if (page_dir_l3.entries[l3_index] == null)
    {
      page_dir_l2 = try allocator.create(Page_Directory_L2);
      page_dir_l3.entries[l3_index] = page_dir_l2;
      page_dir_l2.entries = [_]?*Page_Directory_L1{null} ** PAGE_DIRECTORY_L2_SIZE;
    }
    else
    {
      page_dir_l2 = page_dir_l3.entries[l3_index].?;
    }
  }
  
  // NOTE(fakhri): get level 1 page directory
  {
    if (page_dir_l2.entries[l2_index] == null)
    {
      page_dir_l1 = try allocator.create(Page_Directory_L1);
      page_dir_l2.entries[l2_index] = page_dir_l1;
    }
    else
    {
      page_dir_l1 = page_dir_l2.entries[l2_index].?;
    }
  }
  
  page_dir_l1.entries[l1_index] = phys_address;
  
  var virt_address: u64 = 0;
  virt_address |= (l3_index << (PAGE_DIRECTORY_L2_BITS + PAGE_DIRECTORY_L1_BITS + PAGE_SIZE_BITS));
  virt_address |= (l2_index << (PAGE_DIRECTORY_L1_BITS + PAGE_SIZE_BITS));
  virt_address |= (l1_index << PAGE_SIZE_BITS);
  return virt_address;
}

fn init_page_directory(allocator: std.mem.Allocator) !*Page_Directory_L4
{
  var page_directory = try allocator.create(Page_Directory_L4);
  page_directory.next_virt_addr = 0;
  page_directory.entries = [_]?*Page_Directory_L3{null} ** PAGE_DIRECTORY_L4_SIZE;
  
  return page_directory;
}

pub fn main() !void
{
  var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
  defer arena.deinit();
  const allocator = arena.allocator();
  
  var proc1 = try init_page_directory(allocator);
  var proc2 = try init_page_directory(allocator);
  
  const proc1_virt_addr1  = try allocate_physical_page(proc1, allocator);
  const proc1_virt_addr2  = try allocate_physical_page(proc1, allocator);
  const proc2_virt_addr1  = try allocate_physical_page(proc2, allocator);
  const proc2_virt_addr2  = try allocate_physical_page(proc2, allocator);
  const proc1_virt_addr3  = try allocate_physical_page(proc1, allocator);
  const proc2_virt_addr3  = try allocate_physical_page(proc2, allocator);
  const proc1_virt_addr4  = try allocate_physical_page(proc1, allocator);
  const proc2_virt_addr4  = try allocate_physical_page(proc2, allocator);
  
  const proc1_phys_addr1 = try translate_virt_addr(proc1, proc1_virt_addr1);
  const proc1_phys_addr2 = try translate_virt_addr(proc1, proc1_virt_addr2);
  const proc1_phys_addr3 = try translate_virt_addr(proc1, proc1_virt_addr3);
  const proc1_phys_addr4 = try translate_virt_addr(proc1, proc1_virt_addr4);
  
  std.debug.print("virt_addr1: 0x{X:0>16} for proc1 maps to physical address: 0x{X:0>16}\n", .{proc1_virt_addr1, proc1_phys_addr1});
  std.debug.print("virt_addr2: 0x{X:0>16} for proc1 maps to physical address: 0x{X:0>16}\n", .{proc1_virt_addr2, proc1_phys_addr2});
  std.debug.print("virt_addr3: 0x{X:0>16} for proc1 maps to physical address: 0x{X:0>16}\n", .{proc1_virt_addr3, proc1_phys_addr3});
  std.debug.print("virt_addr41 0x{X:0>16} for proc1 maps to physical address: 0x{X:0>16}\n\n", .{proc1_virt_addr4, proc1_phys_addr4});
  
  const proc2_phys_addr1 = try translate_virt_addr(proc2, proc2_virt_addr1);
  const proc2_phys_addr2 = try translate_virt_addr(proc2, proc2_virt_addr2);
  const proc2_phys_addr3 = try translate_virt_addr(proc2, proc2_virt_addr3);
  const proc2_phys_addr4 = try translate_virt_addr(proc2, proc2_virt_addr4);
  
  std.debug.print("virt_addr1: 0x{X:0>16} for proc2 maps to physical address: 0x{X:0>16}\n", .{proc2_virt_addr1, proc2_phys_addr1});
  std.debug.print("virt_addr2: 0x{X:0>16} for proc2 maps to physical address: 0x{X:0>16}\n", .{proc2_virt_addr2, proc2_phys_addr2});
  std.debug.print("virt_addr3: 0x{X:0>16} for proc2 maps to physical address: 0x{X:0>16}\n", .{proc2_virt_addr3, proc2_phys_addr3});
  std.debug.print("virt_addr41 0x{X:0>16} for proc2 maps to physical address: 0x{X:0>16}\n", .{proc2_virt_addr4, proc2_phys_addr4});
  
}
