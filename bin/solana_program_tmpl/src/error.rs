use solana_program::program_error::ProgramError;

#[derive(thiserror::Error, Debug)]
pub enum MyError {
    #[error("todo")]
    Custom,
}

impl From<MyError> for ProgramError {
    fn from(value: MyError) -> Self {
        ProgramError::Custom(value as u32)
    }
}
