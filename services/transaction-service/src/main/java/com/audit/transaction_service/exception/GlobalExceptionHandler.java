package com.audit.transaction_service.exception;

import com.audit.transaction_service.dto.ErrorResponseDto;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.bind.support.WebExchangeBindException;

import java.time.LocalDateTime;
import java.util.HashMap;
import java.util.Map;

@RestControllerAdvice
public class GlobalExceptionHandler {

    // Handles two 400 Bad Request envelope formats:
    // - WebExchangeBindException ("Validation Failed"): Field-level bean validation errors with a field->message map
    // - IllegalArgumentException ("Bad Request"): Cross-field business rule failures with a single message string.
    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<ErrorResponseDto> handleIllegalArgument(IllegalArgumentException ex) {
        ErrorResponseDto response = new ErrorResponseDto(
                LocalDateTime.now(),
                HttpStatus.BAD_REQUEST.value(),
                "Bad Request",
                ex.getMessage(),
                null
        );
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(response);
    }

    @ExceptionHandler(WebExchangeBindException.class)
    public ResponseEntity<ErrorResponseDto> handleValidationExceptions(WebExchangeBindException ex) {
        Map<String, String> fieldErrors = new HashMap<>();
        ex.getBindingResult().getFieldErrors().forEach(error ->
                fieldErrors.put(error.getField(), error.getDefaultMessage())
        );

        ErrorResponseDto response = new ErrorResponseDto(
                LocalDateTime.now(),
                HttpStatus.BAD_REQUEST.value(),
                "Validation Failed",
                "Invalid request payload parameters",
                fieldErrors
        );
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(response);
    }

    @ExceptionHandler(UpstreamInferenceException.class)
    public ResponseEntity<ErrorResponseDto> handleUpstreamInferenceException(UpstreamInferenceException ex) {
        HttpStatus status = ex.getUpstreamStatus();

        String errorLabel = (status == HttpStatus.BAD_REQUEST)
                ? "Upstream Validation Failure"
                : "Upstream Inference Failure";

        ErrorResponseDto response = new ErrorResponseDto(
                LocalDateTime.now(),
                status.value(),
                errorLabel,
                ex.getMessage(),
                null
        );
        return ResponseEntity.status(status).body(response);
    }

    @ExceptionHandler(RuntimeException.class)
    public ResponseEntity<ErrorResponseDto> handleRuntimeException(RuntimeException ex) {
        ErrorResponseDto response = new ErrorResponseDto(
                LocalDateTime.now(),
                HttpStatus.INTERNAL_SERVER_ERROR.value(),
                "Internal Server Error",
                ex.getMessage(),
                null
        );
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(response);
    }
}