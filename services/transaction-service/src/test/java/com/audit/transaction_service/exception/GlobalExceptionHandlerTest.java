package com.audit.transaction_service.exception;

import com.audit.transaction_service.dto.ErrorResponseDto;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.server.ResponseStatusException;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ResponseStatusException is itself a RuntimeException, so it must be handled ahead
 * of the generic RuntimeException handler or its real status is discarded and every
 * case is reported as 500.
 */
class GlobalExceptionHandlerTest {

    private static final GlobalExceptionHandler HANDLER = new GlobalExceptionHandler();

    @Test
    void responseStatusExceptionReportsItsOwnStatusNotFiveHundred() {
        ResponseStatusException ex = new ResponseStatusException(
                HttpStatus.UNSUPPORTED_MEDIA_TYPE, "Content-Type 'text/plain' not supported");

        ResponseEntity<ErrorResponseDto> response = HANDLER.handleResponseStatusException(ex);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.UNSUPPORTED_MEDIA_TYPE);
        assertThat(response.getBody().getStatus()).isEqualTo(415);
        assertThat(response.getBody().getMessage()).contains("Content-Type 'text/plain' not supported");
    }

    @Test
    void genericRuntimeExceptionStillReportsFiveHundred() {
        RuntimeException ex = new RuntimeException("unexpected failure");

        ResponseEntity<ErrorResponseDto> response = HANDLER.handleRuntimeException(ex);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR);
        assertThat(response.getBody().getStatus()).isEqualTo(500);
    }

    @Test
    void responseStatusExceptionWithNoReasonFallsBackToTheExceptionMessage() {
        ResponseStatusException ex = new ResponseStatusException(HttpStatus.BAD_REQUEST);

        ResponseEntity<ErrorResponseDto> response = HANDLER.handleResponseStatusException(ex);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
        assertThat(response.getBody().getMessage()).isNotNull();
    }
}
