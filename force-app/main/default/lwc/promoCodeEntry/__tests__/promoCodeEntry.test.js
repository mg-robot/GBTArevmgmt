import { createElement } from 'lwc';
import PromoCodeEntry from 'c/promoCodeEntry';
import applyCodes from '@salesforce/apex/PromoCodeApplyService.apply';

jest.mock(
    '@salesforce/apex/PromoCodeApplyService.apply',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

const TEST_ORDER_ID = '801XXXXXXXXXXXXXXX';

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

function buildElement() {
    const el = createElement('c-promo-code-entry', { is: PromoCodeEntry });
    el.orderId = TEST_ORDER_ID;
    document.body.appendChild(el);
    return el;
}

describe('c-promo-code-entry', () => {
    afterEach(() => {
        while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
        applyCodes.mockReset();
    });

    test('renders the Add Promo Code button by default (no input revealed)', () => {
        const el = buildElement();
        const addButton = el.shadowRoot.querySelector('lightning-button');
        expect(addButton).not.toBeNull();
        expect(addButton.label).toBe('Add Promo Code');
        const input = el.shadowRoot.querySelector('.code-input');
        expect(input).toBeNull();
    });

    test('clicking Add Promo Code reveals the input row', async () => {
        const el = buildElement();
        const addButton = el.shadowRoot.querySelector('lightning-button');
        addButton.click();
        await flushPromises();
        const input = el.shadowRoot.querySelector('.code-input');
        expect(input).not.toBeNull();
    });

    test('applying a code calls Apex once with the right args + dispatches codesapplied on success', async () => {
        applyCodes.mockResolvedValue({
            codeResults: [
                {
                    code: 'SAVE10',
                    currencyIsoCode: 'USD',
                    displayName: 'Save 10%',
                    appliedAmount: 50,
                    valid: true
                }
            ],
            totalAdjustment: 50,
            repriceRequired: true,
            applicationGroupId: 'group-1'
        });

        const el = buildElement();
        const onApplied = jest.fn();
        el.addEventListener('codesapplied', onApplied);

        // Reveal input + type a value
        el.shadowRoot.querySelector('lightning-button').click();
        await flushPromises();
        const input = el.shadowRoot.querySelector('.code-input');
        input.value = 'SAVE10';
        input.dispatchEvent(new CustomEvent('change'));

        // Click Apply
        const buttons = el.shadowRoot.querySelectorAll('lightning-button');
        const applyButton = Array.from(buttons).find((b) => b.label === 'Apply');
        applyButton.click();
        await flushPromises();

        expect(applyCodes).toHaveBeenCalledTimes(1);
        expect(applyCodes).toHaveBeenCalledWith({
            orderId: TEST_ORDER_ID,
            codes: ['SAVE10']
        });
        expect(onApplied).toHaveBeenCalledTimes(1);
        expect(onApplied.mock.calls[0][0].detail).toEqual({
            applicationGroupId: 'group-1',
            codes: [
                {
                    code: 'SAVE10',
                    currencyIsoCode: 'USD',
                    displayName: 'Save 10%',
                    appliedAmount: 50
                }
            ],
            totalAdjustment: 50
        });

        const appliedRow = el.shadowRoot.querySelector('.code-row--applied');
        expect(appliedRow).not.toBeNull();
    });

    test('invalid code renders red error banner + dispatches validationerror', async () => {
        applyCodes.mockResolvedValue({
            codeResults: [
                {
                    code: 'BAD',
                    valid: false,
                    errorCode: 'NOT_FOUND',
                    errorMessage: 'Code "BAD" was not found.'
                }
            ],
            totalAdjustment: 0,
            repriceRequired: false,
            applicationGroupId: null
        });

        const el = buildElement();
        const onError = jest.fn();
        el.addEventListener('validationerror', onError);

        el.shadowRoot.querySelector('lightning-button').click();
        await flushPromises();
        const input = el.shadowRoot.querySelector('.code-input');
        input.value = 'BAD';
        input.dispatchEvent(new CustomEvent('change'));

        const applyButton = Array.from(el.shadowRoot.querySelectorAll('lightning-button'))
            .find((b) => b.label === 'Apply');
        applyButton.click();
        await flushPromises();

        expect(onError).toHaveBeenCalledTimes(1);
        expect(onError.mock.calls[0][0].detail.codeResults[0].errorCode).toBe('NOT_FOUND');

        const failedRow = el.shadowRoot.querySelector('.code-row--failed');
        expect(failedRow).not.toBeNull();
        const banner = el.shadowRoot.querySelector('.error-banner');
        expect(banner.textContent).toContain('not found');
    });

    test('removing an applied code re-applies with smaller list + dispatches codesremoved', async () => {
        // First call: apply two codes
        applyCodes.mockResolvedValueOnce({
            codeResults: [
                { code: 'A', currencyIsoCode: 'USD', valid: true, appliedAmount: 10, displayName: 'A' },
                { code: 'B', currencyIsoCode: 'USD', valid: true, appliedAmount: 5, displayName: 'B' }
            ],
            totalAdjustment: 15,
            repriceRequired: true,
            applicationGroupId: 'group-1'
        });
        // Second call: re-apply with B removed
        applyCodes.mockResolvedValueOnce({
            codeResults: [
                { code: 'A', currencyIsoCode: 'USD', valid: true, appliedAmount: 10, displayName: 'A' }
            ],
            totalAdjustment: 10,
            repriceRequired: true,
            applicationGroupId: 'group-2'
        });

        const el = buildElement();
        el.setAppliedCodes([
            { code: 'A', currencyIsoCode: 'USD', displayName: 'A', appliedAmount: 10 },
            { code: 'B', currencyIsoCode: 'USD', displayName: 'B', appliedAmount: 5 }
        ]);
        await flushPromises();

        const onRemoved = jest.fn();
        el.addEventListener('codesremoved', onRemoved);

        // Find the Remove icon-button for code B
        const removeIcons = el.shadowRoot.querySelectorAll('lightning-button-icon[data-code]');
        const bRemove = Array.from(removeIcons).find((b) => b.dataset.code === 'B');
        expect(bRemove).toBeDefined();
        bRemove.click();
        await flushPromises();

        expect(applyCodes).toHaveBeenCalledTimes(1);
        expect(applyCodes).toHaveBeenCalledWith({
            orderId: TEST_ORDER_ID,
            codes: ['A']
        });
        expect(onRemoved).toHaveBeenCalledTimes(1);
    });

    test('removing the last applied code skips Apex + still dispatches codesremoved', async () => {
        const el = buildElement();
        el.setAppliedCodes([
            { code: 'ONLY', currencyIsoCode: 'USD', displayName: 'Only', appliedAmount: 10 }
        ]);
        await flushPromises();

        const onRemoved = jest.fn();
        el.addEventListener('codesremoved', onRemoved);

        const removeBtn = el.shadowRoot.querySelector('lightning-button-icon[data-code="ONLY"]');
        removeBtn.click();
        await flushPromises();

        expect(applyCodes).not.toHaveBeenCalled();
        expect(onRemoved).toHaveBeenCalledTimes(1);
        // Applied row is gone
        expect(el.shadowRoot.querySelector('.code-row--applied')).toBeNull();
    });

    test('disabled=true disables all controls', async () => {
        const el = buildElement();
        el.disabled = true;
        await flushPromises();

        const addBtn = el.shadowRoot.querySelector('lightning-button');
        expect(addBtn.disabled).toBe(true);
    });
});
