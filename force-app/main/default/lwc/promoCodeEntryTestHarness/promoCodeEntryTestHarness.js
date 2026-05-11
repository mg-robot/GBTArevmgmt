import { LightningElement, track } from 'lwc';
import triggerReprice from '@salesforce/apex/PromoCodeTestHarnessController.triggerReprice';
import simulatePrePlaceValidation from '@salesforce/apex/PromoCodeTestHarnessController.simulatePrePlaceValidation';
import resetTestData from '@salesforce/apex/PromoCodeTestHarnessController.resetTestData';

/**
 * Dev / QA harness for the promoCodeEntry LWC. Lets a tester drop in any Order Id, exercise the
 * apply / remove flow, and run the three utility actions surfaced by PromoCodeTestHarnessController.
 *
 * Captures every event emitted by the inner LWC and every Apex response into the on-page event
 * log so the tester can verify the data contract without opening the dev console.
 *
 * Not intended for production use — gated by the Promo_Code_Manager permission set the same way
 * the underlying controller is.
 */
export default class PromoCodeEntryTestHarness extends LightningElement {
    orderId = '';
    isLoading = false;
    @track events = [];
    _eventIdCounter = 0;

    get hasOrderId() {
        return !!(this.orderId && this.orderId.trim());
    }

    get hasOutput() {
        return this.events.length > 0 && !this.isLoading;
    }

    handleOrderIdChange(event) {
        this.orderId = (event.target.value || '').trim();
    }

    // -----------------------------------------------------------
    // Child LWC events
    // -----------------------------------------------------------

    handleCodesApplied(event) {
        this._log('event: codesapplied', event.detail);
    }

    handleCodesRemoved(event) {
        this._log('event: codesremoved', event.detail);
    }

    handleValidationError(event) {
        this._log('event: validationerror', event.detail, { isError: true });
    }

    // -----------------------------------------------------------
    // Utility action handlers
    // -----------------------------------------------------------

    async handleReprice() {
        this.isLoading = true;
        try {
            const snapshot = await triggerReprice({ orderId: this.orderId });
            this._log('triggerReprice → PCI snapshot', snapshot);
        } catch (err) {
            this._log('triggerReprice failed', err, { isError: true });
        } finally {
            this.isLoading = false;
        }
    }

    async handlePrePlace() {
        this.isLoading = true;
        try {
            const results = await simulatePrePlaceValidation({ orderId: this.orderId });
            this._log('simulatePrePlaceValidation → CodeResults', results);
        } catch (err) {
            this._log('simulatePrePlaceValidation failed', err, { isError: true });
        } finally {
            this.isLoading = false;
        }
    }

    async handleReset() {
        this.isLoading = true;
        try {
            const message = await resetTestData({ orderId: this.orderId });
            this._log('resetTestData', message);
        } catch (err) {
            this._log('resetTestData failed', err, { isError: true });
        } finally {
            this.isLoading = false;
        }
    }

    handleClearOutput() {
        this.events = [];
    }

    // -----------------------------------------------------------
    // Internals
    // -----------------------------------------------------------

    _log(label, body, { isError = false } = {}) {
        this._eventIdCounter += 1;
        let displayBody;
        if (body == null) {
            displayBody = '(none)';
        } else if (typeof body === 'string') {
            displayBody = body;
        } else if (body instanceof Error) {
            displayBody = body.message;
        } else {
            try {
                displayBody = JSON.stringify(body, null, 2);
            } catch {
                displayBody = String(body);
            }
        }
        this.events = [
            {
                id: this._eventIdCounter,
                label,
                body: displayBody,
                timestamp: new Date().toLocaleTimeString(),
                rowClass: isError ? 'event-row event-row--error' : 'event-row'
            },
            ...this.events
        ].slice(0, 50);
    }
}
