use std::convert::TryFrom;
use std::error::Error;
use std::sync::Arc;

use crate::error::BuzzError;
use crate::internal_err;
use arrow::datatypes::Schema;
use arrow::ipc::writer::IpcWriteOptions;
use arrow::record_batch::RecordBatch;
use arrow_flight::utils::{
    flight_data_from_arrow_batch, flight_data_from_arrow_schema,
    flight_data_to_arrow_batch,
};
use arrow_flight::{flight_descriptor, FlightData, FlightDescriptor};
use datafusion::physical_plan::SendableRecordBatchStream;
use futures::{Stream, StreamExt};

/// Convert a flight stream to a tuple with the cmd in the first flight and a stream of RecordBatch
pub async fn flight_to_batches(
    flights: tonic::Streaming<FlightData>,
) -> Result<(String, impl Stream<Item = RecordBatch>), Box<dyn Error>> {
    let mut flights = Box::pin(flights);
    let flight_data = flights.next().await.unwrap()?;
    let schema = Arc::new(Schema::try_from(&flight_data)?);
    let cmd = descriptor_to_cmd(flight_data.flight_descriptor)?;

    // all the remaining stream messages should be dictionary and record batches
    let record_batch_stream = flights.map(move |flight_data| {
        flight_data_to_arrow_batch(&flight_data.unwrap(), schema.clone())
            .unwrap()
            .unwrap()
    });
    Ok((cmd, record_batch_stream))
}

/// Convert RecordBatches and a cmd to a stream of flights
pub fn batches_to_flight(
    cmd: &str,
    batches: SendableRecordBatchStream,
) -> Result<impl Stream<Item = FlightData> + Send + Sync, Box<dyn Error>> {
    // TODO are all this IpcWriteOptions creations a problem?

    // create an initial FlightData message that sends schema
    let options = IpcWriteOptions::default();
    let mut flight_schema = flight_data_from_arrow_schema(&batches.schema(), &options);
    flight_schema.flight_descriptor = cmd_to_descriptor(cmd);
    let stream_head = futures::stream::iter(vec![flight_schema]);

    // then stream the rest
    let stream_body = batches.flat_map(|batch| {
        let options = IpcWriteOptions::default();
        futures::stream::iter(flight_data_from_arrow_batch(&batch.unwrap(), &options))
    });

    Ok(stream_head.chain(stream_body))
}

fn cmd_to_descriptor(cmd: &str) -> Option<FlightDescriptor> {
    Some(FlightDescriptor {
        r#type: flight_descriptor::DescriptorType::Cmd as i32,
        cmd: cmd.as_bytes().to_owned(),
        path: vec![],
    })
}

fn descriptor_to_cmd(
    descriptor: Option<FlightDescriptor>,
) -> Result<String, Box<dyn Error>> {
    let descriptor = descriptor.ok_or(Box::new(internal_err!(
        "Descriptor not found in first flight"
    )))?;
    if descriptor.r#type != flight_descriptor::DescriptorType::Cmd as i32 {
        Err(Box::new(internal_err!("Descriptor type should be cmd")))
    } else {
        Ok(String::from_utf8(descriptor.cmd).unwrap())
    }
}
