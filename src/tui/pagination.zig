pub const default_account_page_size: usize = 20;

pub fn shouldPaginate(total_accounts: usize, page_size: usize) bool {
    return page_size != 0 and total_accounts > page_size;
}

pub fn pageCount(total_accounts: usize, page_size: usize) usize {
    if (total_accounts == 0 or page_size == 0) return 0;
    return (total_accounts + page_size - 1) / page_size;
}
