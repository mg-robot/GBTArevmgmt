import { LightningElement, api, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import generateReceipt from '@salesforce/apex/OrderReceiptController.generateReceipt';

export default class OrderReceiptButton extends LightningElement {
    @api recordId;
    isLoading = false;
    pageRef;

    @wire(CurrentPageReference)
    handlePageRef(ref) {
        this.pageRef = ref;
    }

    get effectiveRecordId() {
        return this.recordId || this.pageRef?.state?.recordId;
    }

    handleDownload() {
        if (!this.effectiveRecordId) {
            this.showToast('Error', 'No Order ID available.', 'error');
            return;
        }
        this.isLoading = true;
        generateReceipt({ recordId: this.effectiveRecordId })
            .then(base64 => {
                const link = document.createElement('a');
                link.href = 'data:application/pdf;base64,' + base64;
                link.download = 'Receipt-' + this.effectiveRecordId + '.pdf';
                document.body.appendChild(link);
                link.click();
                document.body.removeChild(link);
            })
            .catch(error => {
                this.showToast('Error', error?.body?.message || 'Failed to generate receipt.', 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}