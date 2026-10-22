use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CellularLine {
    pub iccid: String,
    pub number: Option<String>,
    pub source: String,
}
