package com.audit.transaction_service.exception;

import org.springframework.http.HttpStatus;

public class UpstreamInferenceException extends RuntimeException {

    private final HttpStatus upstreamStatus;

    public UpstreamInferenceException(String message, Throwable cause) {
        this(message, cause, HttpStatus.BAD_GATEWAY);
    }

    public UpstreamInferenceException(String message, Throwable cause, HttpStatus upstreamStatus) {
        super(message, cause);
        this.upstreamStatus = (upstreamStatus != null) ? upstreamStatus : HttpStatus.BAD_GATEWAY;
    }

    public HttpStatus getUpstreamStatus() {
        return upstreamStatus;
    }
}