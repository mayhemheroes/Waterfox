# Build Stage
FROM ghcr.io/evanrichter/cargo-fuzz:latest as builder

## Add source code to the build stage.
ADD . /src
WORKDIR /src

RUN echo building instrumented harnesses && \
    bash -c "pushd gfx/qcms/fuzz && cargo +nightly -Z sparse-registry fuzz build && popd" && \
    mv gfx/qcms/fuzz/target/x86_64-unknown-linux-gnu/release/fuzz_target_qcms /fuzz_target_qcms && \
    echo done

RUN echo building non-instrumented harnesses && \
    export RUSTFLAGS="--cfg fuzzing -Clink-dead-code -Cdebug-assertions -C codegen-units=1" && \
    bash -c "pushd gfx/qcms/fuzz && cargo +nightly -Z sparse-registry build --release && popd" && \
    mv gfx/qcms/fuzz/target/release/fuzz_target_qcms /fuzz_target_qcms_no_inst && \
    echo done

# Package Stage
FROM rustlang/rust:nightly

COPY --from=builder /fuzz_target_qcms /fuzz_target_qcms_no_inst /
