use solana_program::program_error::ProgramError;

#[derive(thiserror::Error)]
pub enum MyError {}

impl From<MyError> for ProgramError {
    fn from(value: MyError) -> Self {
        ProgramError::Custom(value as u32)
    }
}
