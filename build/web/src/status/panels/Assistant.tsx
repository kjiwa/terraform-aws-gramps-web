import type { ComponentChildren } from 'preact';
import { useState } from 'preact/hooks';
import type {
  Assistant as AssistantData,
  PanelError,
  TokenSeries,
} from '../../generated/status-payload';
import { fmtCompact, numOrDash } from '../../shared/format';
import { LineChart } from '../charts/LineChart';
import { useResettableIndex } from '../inspect';
import {
  availableRanges,
  defaultSelected,
  relativeLabel,
  windowAxisLabels,
  type RangeKey,
} from '../ranges';
import { useSeries } from '../series';
import { Card, ErrNote } from '../ui/Card';
import { Inspector } from '../ui/Inspector';
import { Kv } from '../ui/Kv';
import { LegendPair } from '../ui/LegendPair';
import { RangeSelector } from '../ui/RangeSelector';
import { StatRow } from '../ui/StatRow';
import { WindowNav } from '../ui/WindowNav';

/**
 * Tokens are spend-shaped, but Cost is off in prod (COST_ENABLED gates it
 * server-side) -- moving them onto the Cost card would delete them from the
 * live page entirely, so they stay here as Assistant's own range-switched
 * chart.
 */
function sumTokens(arr: number[] | undefined): number {
  return (arr || []).reduce((a, b) => a + b, 0);
}

export function Assistant({
  d,
  canPan,
}: {
  d: AssistantData | PanelError | undefined;
  canPan?: boolean;
}) {
  const tokenRanges: Partial<Record<RangeKey, TokenSeries>> =
    (d && !('error' in d) && d.token_ranges) || {};
  const tokenAvailable = availableRanges((key) => tokenRanges[key] !== undefined);
  const [tokenSelected, setTokenSelected] = useState<RangeKey | undefined>(() =>
    defaultSelected(tokenAvailable),
  );
  const [tokenEnd, setTokenEnd] = useState<string | null>(null);
  const series = useSeries<AssistantData>('assistant', tokenSelected, tokenEnd);
  const [tokenIndex, setTokenIndex] = useResettableIndex(`${tokenSelected}:${tokenEnd}`);

  if (!d) return null;
  if ('error' in d) {
    return (
      <Card title="Assistant">
        <ErrNote message={d.error} />
      </Card>
    );
  }

  // Panning replaces this range's token arrays -- and, since input/
  // outputSum below are sums over exactly that array, their totals move
  // with it too. That's still "replacing only the series array inside the
  // selected range," per the parent plan: unlike Host's `current` gauge,
  // these sums have no separate live counterpart to preserve.
  const seriesA = series.data && !('error' in series.data) ? series.data : undefined;
  const r =
    (tokenSelected && seriesA?.token_ranges[tokenSelected]) ??
    (tokenSelected ? tokenRanges[tokenSelected] : undefined);
  const inputSum = sumTokens(r?.input);
  const outputSum = sumTokens(r?.output);
  const count = Math.max(r?.input?.length ?? 0, r?.output?.length ?? 0);

  // At rest (tokenIndex === null), the original never shows a per-point
  // value here at all -- this is a plain color legend, with the range's
  // *summed* totals living in the StatRow below instead. Inspecting a
  // specific bucket has no equivalent "current" fallback the way Host's
  // gauges do, so it's the only state that shows a per-bucket number,
  // alongside how long ago that bucket was.
  function keyItems(): ComponentChildren[] {
    if (tokenIndex === null) {
      return [
        <LegendPair key="in" cls="c-chart1" label="input" />,
        <LegendPair key="out" cls="c-chart2" label="output" />,
      ];
    }
    const inV = r?.input?.[tokenIndex];
    const outV = r?.output?.[tokenIndex];
    return [
      <LegendPair key="in" cls="c-chart1" label={`input ${numOrDash(inV)}`} />,
      <LegendPair key="out" cls="c-chart2" label={`output ${numOrDash(outV)}`} />,
      tokenSelected && (
        <span key="when">
          {relativeLabel(tokenSelected, tokenIndex, count, tokenEnd !== null ? series.end : null)}
        </span>
      ),
    ];
  }

  function describeIndex(i: number): string {
    if (!tokenSelected) return '';
    const inV = r?.input?.[i];
    const outV = r?.output?.[i];
    return `input ${numOrDash(inV)}, output ${numOrDash(outV)}, ${relativeLabel(tokenSelected, i, count, tokenEnd !== null ? series.end : null)}`;
  }

  return (
    <Card title="Assistant">
      <div class="subgrid">
        <div>
          <h4>Model</h4>
          <Kv
            pairs={[
              ['ID', d.model_id],
              ['Region', d.region],
              ['Max requests', d.max_requests],
              ['Max tokens/run', numOrDash(d.max_tokens)],
              ['Max context', numOrDash(d.max_context_length)],
            ]}
          />
        </div>
        <div>
          <h4>Tokens</h4>
          {tokenAvailable.length > 0 && (
            <>
              <RangeSelector
                available={tokenAvailable}
                selected={tokenSelected ?? ''}
                onSelect={(v) => setTokenSelected(v as RangeKey)}
              />
              {canPan && tokenSelected && (
                <WindowNav
                  range={tokenSelected}
                  end={tokenEnd}
                  echoedEnd={series.end}
                  onChange={setTokenEnd}
                />
              )}
              {series.error && <ErrNote message={series.error} />}
              {/* Chart, key and totals share one wrapper -- not two -- so
                  `.chart-key + .stat-row` (see status.css) actually
                  matches. */}
              <div
                class={series.loading ? 'panning' : undefined}
                aria-busy={series.loading || undefined}
              >
                {r && (
                  <>
                    <LineChart
                      series={[
                        { values: r.input, colorVar: '--gw-chart-1' },
                        { values: r.output, colorVar: '--gw-chart-2' },
                      ]}
                      opts={{
                        min: 0,
                        yFormat: fmtCompact,
                        compact: true,
                        ...windowAxisLabels(tokenSelected, tokenEnd !== null ? series.end : null),
                        ariaLabel: `Input and output tokens over ${tokenSelected}`,
                        describeIndex,
                      }}
                      inspect={{ index: tokenIndex, onIndex: setTokenIndex }}
                    />
                    <Inspector>{keyItems()}</Inspector>
                    <StatRow
                      tight
                      items={[
                        [numOrDash(inputSum), 'input'],
                        [numOrDash(outputSum), 'output'],
                        [numOrDash(inputSum + outputSum), 'total'],
                      ]}
                    />
                  </>
                )}
              </div>
            </>
          )}
        </div>
      </div>
    </Card>
  );
}
